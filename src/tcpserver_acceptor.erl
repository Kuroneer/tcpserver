%%%-------------------------------------------------------------------
%%% @doc Accepts sockets connections and lets Workers handle them
%%% @end
%%% Part of tcpserver Erlang App
%%% MIT License
%%% Copyright (c) 2019 Jose Maria Perez Ramos
%%%-------------------------------------------------------------------
-module(tcpserver_acceptor).

%% API
-export([
         start_link/2,
         start_link/3,
         start_link/4
        ]).

-define(UNIFORM_RANGE, 50).


%%====================================================================
%% API functions
%%====================================================================

-spec start_link(gen_tcp:socket(), fun()) -> pid().
start_link(ListenSocket, WorkerSpawner) ->
    start_link(ListenSocket, WorkerSpawner, false, infinity).

-spec start_link(gen_tcp:socket(), fun(), boolean() | pos_integer() | infinity) -> pid().
start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway) when is_boolean(NotifyAfterSocketGiveaway) ->
    start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, infinity);
start_link(ListenSocket, WorkerSpawner, AcceptTimeout) ->
    start_link(ListenSocket, WorkerSpawner, false, AcceptTimeout).

-spec start_link(gen_tcp:socket(), fun(), boolean(), pos_integer() | infinity) -> pid().
start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout) ->
    spawn_link(fun() -> PositiveAcceptTimeout = case AcceptTimeout of
                                                    infinity ->
                                                        infinity;
                                                    _ ->
                                                        % With AcceptTimeout,
                                                        % the process will wait
                                                        % for it to handle signals
                                                        process_flag(trap_exit, true),
                                                        rand:seed(exrop),
                                                        max(AcceptTimeout, ?UNIFORM_RANGE + 1)
                                                end,
                        accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, PositiveAcceptTimeout)
               end).


%%====================================================================
%% Internal functions
%%====================================================================

accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout) ->
    AcceptTimeoutWithOffset = case AcceptTimeout of
                                  infinity ->
                                      infinity;
                                  _ ->
                                      check_inbox(),
                                      AcceptTimeout + rand:uniform(2 * ?UNIFORM_RANGE) - ?UNIFORM_RANGE
                              end,
    case gen_tcp:accept(ListenSocket, AcceptTimeoutWithOffset) of
        {ok, AcceptSocket} ->
            WorkerPid = create_worker(WorkerSpawner, AcceptSocket),
            if is_pid(WorkerPid) ->
                   case {gen_tcp:controlling_process(AcceptSocket, WorkerPid), NotifyAfterSocketGiveaway} of
                       {ok, true} ->
                           WorkerPid ! {socket_is_yours, AcceptSocket};
                       {ok, _} ->
                           ok;
                       {{error, closed}, _} ->
                           ok;
                       {{error, Reason}, _} ->
                           logger:error("~p (~p): Error while transferring control of socket: ~p", [?MODULE, self(), Reason]),
                           gen_tcp:close(AcceptSocket)
                   end;
               true ->
                   gen_tcp:close(AcceptSocket)
            end,
            accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout);
        {error, timeout} ->
            accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway, AcceptTimeout);
        {error, Reason} ->
            exit(Reason)
    end.

check_inbox() ->
    receive
        {'EXIT', _From, Reason} -> exit(Reason);
        _ -> check_inbox()
    after 0 -> ok
    end.

%% Get a worker for the socket
%% Workers MUST link to the Accepted to receive the socket shutdown
%% should an error happen before transferring the control of the socket (such as
%% premature close)
%% If workers rely on the notify_socket_transfer, they SHOULD link to the
%% acceptor's Pid (retrieved by self() in the callback) to handle the possible
%% kill between the controlling_process call and the socket_is_yours message send
create_worker(SpawnerFunction, AcceptSocket) when is_function(SpawnerFunction) ->
    SpawnerFunction(AcceptSocket);
create_worker({M, F, A}, AcceptSocket) ->
    apply(M, F, A ++ [AcceptSocket]);
create_worker({M, F}, AcceptSocket) ->
    create_worker({M, F, []}, AcceptSocket);
create_worker(M, AcceptSocket) when is_atom(M) ->
    create_worker({M, create_worker}, AcceptSocket).

