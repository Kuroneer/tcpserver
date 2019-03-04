%%% Listens in a socket and maintains a pool of acceptors running

-module(tcpserver_listener).

-behaviour(gen_server).

%% API
-export([
         start_link/4,
         set_acceptors_num/2,
         get_socket_from_child/1
        ]).

%% Gen_server callbacks
-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         handle_info/2,
         terminate/2
        ]).


-record(state, {
          port,
          listen_socket,
          worker_spawner,
          notify_socket_transfer = false,
          acceptors_target_number = 0,
          acceptors_size = 0,
          acceptors = #{}
         }).


-define(SLEEP_TIME, 1000).
-define(MAX_BURST, 30).


%%====================================================================
%% API functions
%%====================================================================

start_link(Port, WorkerSpawner, ListeningOptions, AcceptorsNumber) ->
    gen_server:start_link(?MODULE, {Port, WorkerSpawner, ListeningOptions, AcceptorsNumber}, []).


set_acceptors_num(Pid, NewAcceptors) ->
    gen_server:call(Pid, {new_acceptors, NewAcceptors}).


get_socket_from_child(Pid) ->
    #state{listen_socket = ListenSocket} = sys:get_state(Pid),
    ListenSocket.


%%====================================================================
%% Gen_server callbacks
%%====================================================================

init({Port, WorkerSpawner, ListeningOptions, AcceptorsNumber}) ->
    IntPort = case Port of
                  P when is_integer(P) -> P;
                  _ -> 0
              end,

    process_flag(trap_exit, true),
    {[NotifyAfterSocketGiveaway], FilteredListeningOptions} = proplists:split(ListeningOptions, [notify_socket_transfer]),
    case gen_tcp:listen(IntPort, FilteredListeningOptions) of
        {ok, ListenSocket} ->
            logger:debug("~p (~p): Listening ~p in ~p", [?MODULE, self(), Port, ListenSocket]),
            self() ! check_acceptors,
            {ok, #state{
                    port = Port,
                    listen_socket = ListenSocket,
                    worker_spawner = WorkerSpawner,
                    notify_socket_transfer = proplists:get_value(notify_socket_transfer, NotifyAfterSocketGiveaway),
                    acceptors_target_number = AcceptorsNumber
                   }
            };
        Error -> {stop, Error}
    end.


handle_cast(_, S) ->
    {noreply, S}.


handle_call({new_acceptors, NewAcceptors}, _From, State) ->
    self() ! check_acceptors,
    {reply, ok, State#state{acceptors_target_number = NewAcceptors}};

handle_call(_E, _From, State) ->
    {noreply, State}.


handle_info(check_acceptors, #state{
                                port = Port,
                                listen_socket = ListenSocket,
                                worker_spawner = WorkerSpawner,
                                notify_socket_transfer = NotifyAfterSocketGiveaway,
                                acceptors = Acceptors,
                                acceptors_size = AcceptorsCurrentNumber,
                                acceptors_target_number = AcceptorsTargetNumber
                               } = S) when AcceptorsTargetNumber > AcceptorsCurrentNumber ->
    %% Need to spawn acceptors
    ToCreate = min(?MAX_BURST, AcceptorsTargetNumber - AcceptorsCurrentNumber),
    {NewAcceptors, NewAcceptorsSize} = create_acceptors(
                                         ListenSocket,
                                         WorkerSpawner,
                                         NotifyAfterSocketGiveaway,
                                         ToCreate,
                                         Acceptors,
                                         AcceptorsCurrentNumber
                                        ),

    logger:info("~p (~p): Spawned ~p acceptors for port ~p", [?MODULE, self(), ToCreate, Port]),
    erlang:send_after(?SLEEP_TIME, self(), check_acceptors),
    {noreply, S#state{acceptors = NewAcceptors, acceptors_size = NewAcceptorsSize}};

handle_info(check_acceptors, #state{
                                port = Port,
                                acceptors = Acceptors,
                                acceptors_size = AcceptorsCurrentNumber,
                                acceptors_target_number = AcceptorsTargetNumber
                               } = S) when AcceptorsTargetNumber < AcceptorsCurrentNumber ->
    %% Need to kill acceptors
    ToRemove = min(?MAX_BURST, AcceptorsCurrentNumber - AcceptorsTargetNumber),
    Iterator = maps:iterator(Acceptors),
    {NewAcceptors, NewAcceptorsSize} = remove_acceptors(
                                         Iterator,
                                         ToRemove,
                                         Acceptors,
                                         AcceptorsCurrentNumber
                                        ),

    logger:info("~p (~p): Removed ~p acceptors for port ~p", [?MODULE, self(), ToRemove, Port]),
    erlang:send_after(?SLEEP_TIME, self(), check_acceptors),
    {noreply, S#state{acceptors = NewAcceptors, acceptors_size = NewAcceptorsSize}};

handle_info({'EXIT', ListenSocket, Reason}, #state{listen_socket = ListenSocket} = S) ->
    {noreply, Reason, S};

handle_info({'EXIT', FromPid, Reason}, #state{
                                          port = Port,
                                          acceptors = Acceptors,
                                          acceptors_size = AcceptorsSize
                                         } = S) ->

    case Acceptors of
        #{ FromPid := _ } ->
            logger:info("~p (~p): Acceptor for port ~p exited with ~p", [?MODULE, self(), Port, Reason]),
            self() ! check_acceptors,
            {noreply, S#state{
                        acceptors = maps:remove(FromPid, Acceptors),
                        acceptors_size = AcceptorsSize - 1
                       }
            };
        _ ->
            {noreply, S}
    end;

handle_info(_E, S) ->
    {noreply, S}.


terminate(normal, _State) ->
    ok;

terminate(shutdown, _State) ->
    ok;

terminate(Reason, _State) ->
    logger:info("~p (~p): Terminate reason: ~p", [?MODULE, self(), Reason]).


%%====================================================================
%% Internal functions
%%====================================================================

create_acceptors(_, _, _, 0, Acceptors, AcceptorsSize) ->
    {Acceptors, AcceptorsSize};

create_acceptors(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, ToCreate, Acceptors, AcceptorsSize) ->
    AcceptorPid = tcpserver_acceptor:start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway),
    create_acceptors(
      ListenSocket,
      WorkerSpawner,
      NotifyAfterSocketGiveaway,
      ToCreate - 1,
      Acceptors#{AcceptorPid => true},
      AcceptorsSize + 1
     ).


remove_acceptors(_, 0, Acceptors, AcceptorsSize) ->
    {Acceptors, AcceptorsSize};

remove_acceptors(Iterator, ToRemove, Acceptors, AcceptorsSize) ->
    {WorkerPid, _, NextIterator} = maps:next(Iterator),
    exit(WorkerPid, shutdown),
    remove_acceptors(
      NextIterator,
      ToRemove -1,
      maps:remove(WorkerPid, Acceptors),
      AcceptorsSize -1
     ).

