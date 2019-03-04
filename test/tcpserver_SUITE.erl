-module(tcpserver_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").


all() -> [
          startup,
          connect,
          acceptor_crash
         ].


suite() ->
    [{timetrap,{seconds, 30}}].


init_per_suite(Config) ->
    Config.


end_per_suite(_) -> ok.


init_per_testcase(_Case, Config) ->
    Config.


end_per_testcase(_Case, _Config) ->
    application:stop(tcpserver),
    case flush() of
        [] -> ok;
        Messages -> ct:pal("Messages in queue are: ~p", [Messages])
    end,
    ok.


%% =============================================================================
%% Test cases
%% =============================================================================

startup(_Config) ->
    %% Start listener
    {ok, ListenerPid, ListenSocket} = start_listener(startup, fun(_) -> undefined end),

    %% Start again another listener (Starting func is discarded)
    {ok, ListenerPid, ListenSocket} = start_listener(startup, fun(_) -> undefined end),

    %% Try to start another different one in the same port
    {ok, Port} = inet:port(ListenSocket),
    {{error, eaddrinuse}, _ChildSpec} = start_listener(Port, fun(_) -> undefined end),

    %% Now remove it and start it again in the same port but with different name
    ok = tcpserver:remove_port_listener(startup),
    false = is_process_alive(ListenerPid),
    undefined = erlang:port_info(ListenSocket),
    {ok, OtherListenerPid, OtherListenSocket} = start_listener(Port, fun(_) -> undefined end),
    true = is_process_alive(OtherListenerPid),
    false = undefined =:= erlang:port_info(OtherListenSocket),

    ok.


connect(_Config) ->
    Self = self(),
    {ok, ListenerPid, ListenSocket} = start_listener(startup, fun(Socket) -> Self ! {start_worker, Socket}, Self end),
    {ok, Port} = inet:port(ListenSocket),
    %% Start again another listener (Starting func is discarded)
    {ok, ListenerPid, ListenSocket} = start_listener(startup, fun(_) -> undefined end),

    %% Connect (Worker is created)
    {ok, LocalSocket} = gen_tcp:connect({127,0,0,1}, Port, []),
    false = undefined =:= erlang:port_info(LocalSocket),
    AcceptSocket = receive
                       {start_worker, S} -> S
                   after 5000 -> ct:fail("Missing start_worker message")
                   end,

    %% To get notified if the socket gets closed before transfer is complete
    process_flag(trap_exit, true),
    link(AcceptSocket),

    %% Send something
    Binary = <<0,1,2,3,4,5,6>>,
    gen_tcp:send(LocalSocket, Binary),
    receive
        {tcp, AcceptSocket, Binary} -> inet:setopts(AcceptSocket, [{active, once}])
    after 5000 -> ct:fail("Missing tcp message")
    end,

    %% Check that socket transfer works
    receive
        {socket_is_yours, AcceptSocket} -> ok
    after 5000 -> ct:fail("Missing socket_is_yours message")
    end,

    %% Close socket
    gen_tcp:close(LocalSocket),
    receive
        {tcp_closed, AcceptSocket} -> ok
    after 5000 -> ct:fail("Missing tcp_closed message")
    end,

    ok.

%% Acceptor crash all
%% Worker crash

acceptor_crash(_Config) ->
    Self = self(),
    {ok, ListenerPid, ListenSocket} = start_listener(startup, fun(Socket) ->
                                                                      case inet:peername(Socket) of
                                                                          {ok, {{127,0,0,1}, _}} ->
                                                                              error(this_code_is_run_by_the_acceptor);
                                                                          _ ->
                                                                              Self
                                                                      end
                                                              end),
    {ok, Port} = inet:port(ListenSocket),
    {state, _, _, _, _, _, _, Acceptors} = sys:get_state(ListenerPid),

    %% Reduce number of acceptors
    process_flag(trap_exit, true),
    OriginalAcceptorsNum = maps:size(Acceptors),
    NewAcceptorsNum = 10,
    [ link(AcceptorPid) || AcceptorPid <- maps:keys(Acceptors) ],
    tcpserver:change_port_acceptors_number(startup, NewAcceptorsNum),
    [ receive {'EXIT', _, _} -> ok after 5000 -> ct:fail("missing exit message") end || _ <- lists:seq(1, OriginalAcceptorsNum - NewAcceptorsNum) ],

    %% All current acceptors crash
    {state, _, _, _, _, _, _, Acceptors2} = sys:get_state(ListenerPid),
    Sockets = [ element(2, gen_tcp:connect({127,0,0,1}, Port, [])) || _ <- maps:keys(Acceptors2) ],
    [ receive {tcp_closed, S} -> ok after 5000 -> ct:fail("missing tcp_closed message") end || S <- Sockets],

    %% But some other gets accepted
    {ok, LocalSocket} = gen_tcp:connect({127,0,0,1}, Port, [{ip, {127,0,0,2}}]),

    %% controlling_process has finished
    receive
        {socket_is_yours, _} -> ok
    after 5000 -> ct:fail("Missing socket_is_yours message")
    end,

    gen_tcp:close(LocalSocket),
    receive {tcp_closed, _} -> ok after 5000 -> ct:fail("missing tcp_closed message") end,

    ok.


%% =============================================================================
%% Internal functions
%% =============================================================================

start_listener(Port, WorkerSpawner) ->
    Options = [{reuseaddr, true}, {active, once}, {ip, {0,0,0,0}}, {mode, binary}, {packet, raw}, {notify_socket_transfer, true}],
    AcceptorsNum = 25, %% 25 acceptors because it's less than max_burst
    ListenerPid = case tcpserver:add_port_listener(Port, WorkerSpawner, Options, AcceptorsNum) of
                      {ok, Pid} -> Pid;
                      {error, {already_started, Pid}} -> Pid;
                      {error, Error} -> Error
                  end,
    if is_pid(ListenerPid) ->
           poll_until_acceptors_num_reach(ListenerPid, AcceptorsNum),
           {ok, ListenerPid, tcpserver:get_socket_from_child(Port)};
       true ->
           ListenerPid
    end.

poll_until_acceptors_num_reach(ListenerPid, Num) ->
    {state, _, _, _, _, _, _, Acceptors} = sys:get_state(ListenerPid),
    case maps:size(Acceptors) of
        Num ->
            ok;
        _ ->
            timer:sleep(100),
            poll_until_acceptors_num_reach(ListenerPid, Num)
    end.


flush() ->
    receive M -> [M | flush()] after 0 -> [] end.

print(Something) ->
    ct:print("~p~n", [Something]).

