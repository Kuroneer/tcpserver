%%% Listens in a socket and maintains a pool of acceptors running

-module(tcpserver_listener).

%% API
-export([
         start_link/4,
         set_acceptors_num/2,
         get_socket_from_child/1
        ]).

%% gen_server callbacks
-behaviour(gen_server).
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
          accept_timeout = infinity,
          acceptors_target_number = 0,
          acceptors_size = 0,
          acceptors = #{},
          check_acceptors_ref = undefined
         }).

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
%% gen_server callbacks
%%====================================================================

init({Port, WorkerSpawner, ListeningOptions, AcceptorsNumber}) ->
    IntPort = case Port of
                  P when is_integer(P) -> P;
                  _ -> 0
              end,

    process_flag(trap_exit, true),
    NotTcpOptions = [notify_socket_transfer, accept_timeout],
    {[NotifyAfterSocketGiveaway, AcceptTimeout], FilteredListeningOptions} = proplists:split(ListeningOptions, NotTcpOptions),
    case gen_tcp:listen(IntPort, FilteredListeningOptions) of
        {ok, ListenSocket} ->
            logger:debug("~p (~p): Listening ~p in ~p", [?MODULE, self(), Port, ListenSocket]),
            {ok, #state{
                    port = Port,
                    listen_socket = ListenSocket,
                    worker_spawner = WorkerSpawner,
                    notify_socket_transfer = proplists:get_value(notify_socket_transfer, NotifyAfterSocketGiveaway),
                    accept_timeout = proplists:get_value(accept_timeout, AcceptTimeout, infinity),
                    acceptors_target_number = AcceptorsNumber,
                    check_acceptors_ref = send_check_acceptors_msg()
                   }
            };
        Error -> {stop, Error}
    end.

handle_cast(_, S) ->
    {noreply, S}.

handle_call({new_acceptors, NewAcceptors}, _From, State) ->
    CheckAcceptorsRef = undefined,
    {noreply, NewState} = handle_info({check_acceptors, CheckAcceptorsRef},
                                      State#state{
                                        acceptors_target_number = NewAcceptors,
                                        check_acceptors_ref = CheckAcceptorsRef
                                       }),
    {reply, ok, NewState};
handle_call(_E, _From, State) ->
    {noreply, State}.

handle_info({check_acceptors, CheckAcceptorsRef},
            #state{
               port = Port,
               listen_socket = ListenSocket,
               worker_spawner = WorkerSpawner,
               notify_socket_transfer = NotifyAfterSocketGiveaway,
               accept_timeout = AcceptTimeout,
               acceptors = Acceptors,
               acceptors_size = AcceptorsCurrentNumber,
               acceptors_target_number = AcceptorsTargetNumber,
               check_acceptors_ref = CheckAcceptorsRef
              } = S) when AcceptorsTargetNumber > AcceptorsCurrentNumber ->
    %% Need to spawn acceptors
    ToCreate = min(?MAX_BURST, AcceptorsTargetNumber - AcceptorsCurrentNumber),
    {NewAcceptors, NewAcceptorsSize} = create_acceptors(
                                         ListenSocket,
                                         WorkerSpawner,
                                         NotifyAfterSocketGiveaway,
                                         AcceptTimeout,
                                         ToCreate,
                                         Acceptors,
                                         AcceptorsCurrentNumber
                                        ),

    logger:info("~p (~p): Spawned ~p acceptors for port ~p", [?MODULE, self(), ToCreate, Port]),
    {noreply, S#state{
                acceptors = NewAcceptors,
                acceptors_size = NewAcceptorsSize,
                check_acceptors_ref = send_check_acceptors_msg_after_some_time()
               }};
handle_info({check_acceptors, CheckAcceptorsRef},
            #state{
               port = Port,
               acceptors = Acceptors,
               acceptors_size = AcceptorsCurrentNumber,
               acceptors_target_number = AcceptorsTargetNumber,
               check_acceptors_ref = CheckAcceptorsRef
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
    {noreply, S#state{
                acceptors = NewAcceptors,
                acceptors_size = NewAcceptorsSize,
                check_acceptors_ref = send_check_acceptors_msg_after_some_time()
               }};
handle_info({'EXIT', ListenSocket, Reason}, #state{listen_socket = ListenSocket} = S) ->
    {stop, Reason, S};
handle_info({'EXIT', FromPid, Reason},
            #state{
               port = Port,
               acceptors = Acceptors,
               acceptors_size = AcceptorsSize
              } = S) ->
    case Acceptors of
        #{ FromPid := _ } ->
            logger:info("~p (~p): Acceptor for port ~p exited with ~p", [?MODULE, self(), Port, Reason]),
            {noreply, S#state{
                        acceptors = maps:remove(FromPid, Acceptors),
                        acceptors_size = AcceptorsSize - 1,
                        check_acceptors_ref = send_check_acceptors_msg_after_some_time()
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

send_check_acceptors_msg() ->
    CheckAcceptorsRef = make_ref(),
    self() ! {check_acceptors, CheckAcceptorsRef},
    CheckAcceptorsRef.

send_check_acceptors_msg_after_some_time() ->
    CheckAcceptorsRef = make_ref(),
    erlang:send_after(1000, self(), {check_acceptors, CheckAcceptorsRef}),
    CheckAcceptorsRef.

create_acceptors(_, _, _, _, 0, Acceptors, AcceptorsSize) ->
    {Acceptors, AcceptorsSize};

create_acceptors(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout, ToCreate, Acceptors, AcceptorsSize) ->
    AcceptorPid = tcpserver_acceptor:start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout),
    create_acceptors(
      ListenSocket,
      WorkerSpawner,
      NotifyAfterSocketGiveaway,
      AcceptTimeout,
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

