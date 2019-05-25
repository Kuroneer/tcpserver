%%%-------------------------------------------------------------------
%% @doc Listens in a socket and maintains a pool of acceptors running
%% @end
%%%-------------------------------------------------------------------
% Part of tcpserver Erlang App
% MIT License
% Copyright (c) 2019 Jose Maria Perez Ramos
-module(tcpserver_listener).

%% API
-export([
         start_link/4,
         set_acceptors_num/2,
         get_socket_from_child/1
        ]).

-behaviour(gen_server).
-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(MAX_BURST, 30).


%%====================================================================
%% Types
%%====================================================================

-type worker_spawner() :: fun() | {atom(), atom(), list()} | {atom() | atom()} | atom().
-type port_identifier() :: pos_integer() | atom().

-export_type([
              worker_spawner/0,
              port_identifier/0
             ]).

%% gen_server state
-record(state, {
          port                              :: port_identifier(),
          listen_socket                     :: gen_tcp:socket(),
          worker_spawner                    :: worker_spawner(),
          notify_socket_transfer = false    :: boolean(),
          accept_timeout = infinity         :: timeout(),
          acceptors_target_number = 0       :: non_neg_integer(),
          acceptors_size = 0                :: non_neg_integer(),
          acceptors = #{}                   :: #{pid() => true},
          check_acceptors_ref = undefined   :: undefined | reference()
         }).


%%====================================================================
%% API functions
%%====================================================================

-spec start_link(port_identifier(), worker_spawner(), list(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
start_link(Port, WorkerSpawner, ListeningOptions, AcceptorsNumber) ->
    gen_server:start_link(?MODULE, {Port, WorkerSpawner, ListeningOptions, AcceptorsNumber}, []).

-spec set_acceptors_num(pid(), non_neg_integer()) -> ok.
set_acceptors_num(Pid, NewAcceptors) ->
    gen_server:call(Pid, {new_acceptors, NewAcceptors}).

-spec get_socket_from_child(pid()) -> gen_tcp:socket().
get_socket_from_child(Pid) ->
    #state{listen_socket = ListenSocket} = sys:get_state(Pid),
    ListenSocket.


%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init({port_identifier(), worker_spawner(), list(), non_neg_integer()}) -> {ok, #state{}} | {stop, term()}.
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

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_, S) ->
    {noreply, S}.

-spec handle_call(term(), {pid(), reference()}, #state{}) -> {reply, ok, #state{}} | {noreply, #state{}}.
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

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
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

-spec terminate(term(), #state{}) -> ok.
terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate(Reason, _State) ->
    logger:info("~p (~p): Terminate reason: ~p", [?MODULE, self(), Reason]),
    ok.


-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_Vsn, #state{acceptors = OldAcceptors} = State, _Extra) ->
    % Create new acceptors
    CheckAcceptorsRef = undefined,
    {noreply, NewState} = handle_info({check_acceptors, CheckAcceptorsRef},
                                      State#state{
                                        acceptors = #{},
                                        acceptors_size = 0,
                                        check_acceptors_ref = CheckAcceptorsRef
                                       }),
    % Remove old acceptors
    {#{}, 0} = remove_acceptors(
                 maps:iterator(OldAcceptors),
                 maps:size(OldAcceptors),
                 OldAcceptors,
                 maps:size(OldAcceptors)
                ),
    {ok, NewState}.


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

