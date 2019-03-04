%%% Accepts sockets connections and lets Workers handle them
-module(tcpserver_acceptor).

%% API
-export([
         start_link/2,
         start_link/3
        ]).

%%====================================================================
%% API functions
%%====================================================================

start_link(ListenSocket, WorkerSpawner) ->
    start_link(ListenSocket, WorkerSpawner, false).

start_link(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway) ->
    spawn_link(fun() -> accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway) end).

%% Accepting a connection
accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway) ->
    case gen_tcp:accept(ListenSocket) of
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
            accept(ListenSocket, WorkerSpawner, NotifyAfterSocketGiveaway);

        {error, Reason} ->
            exit(Reason)
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

