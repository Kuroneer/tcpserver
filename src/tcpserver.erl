%%%-------------------------------------------------------------------
%% @doc tcpserver application, public API and top level supervisor
%% @end
%%%-------------------------------------------------------------------
% Part of tcpserver Erlang App
% MIT License
% Copyright (c) 2019 Jose Maria Perez Ramos
-module(tcpserver).

%% API
-export([
         add_port_listener/2,
         add_port_listener/3,
         add_port_listener/4,
         remove_port_listener/1,
         change_port_acceptors_number/2,
         get_socket_from_child/1
        ]).

-behaviour(application).
-export([start/2, stop/1]).

-behaviour(supervisor).
-export([init/1]).

-define(APP, ?MODULE).
-define(DEFAULT_SOCKET_ACCEPTORS, 100).


%%====================================================================
%% Types
%%====================================================================

-type worker_spawner() :: tcpserver_listener:worker_spawner().
-type port_identifier() :: tcpserver_listener:port_identifier().


%%====================================================================
%% API functions
%%====================================================================

-spec add_port_listener(port_identifier(), worker_spawner()) -> {ok, undefined | pid()} | {error, term()}.
add_port_listener(Port, WorkerSpawner) ->
    add_port_listener_int({Port, WorkerSpawner}).

%% Listen options as for gen_tcp:listen:
%% gen_tcp:listen(Port, [{reuseaddr, true}, {active, once}, {ip, {0,0,0,0}}])...
%% plus {accept_timeout, timeout()} and {notify_socket_transfer, boolean()}
-spec add_port_listener(port_identifier(), worker_spawner(), list() | non_neg_integer()) ->
    {ok, undefined | pid()} | {error, term()}.
add_port_listener(Port, WorkerSpawner, ListenOptionsOrAcceptorsNumber) ->
    add_port_listener_int({Port, WorkerSpawner, ListenOptionsOrAcceptorsNumber}).

-spec add_port_listener(port_identifier(), worker_spawner(), list(), non_neg_integer()) ->
    {ok, undefined | pid()} | {error, term()}.
add_port_listener(Port, WorkerSpawner, ListenOptions, AcceptorsNumber) ->
    add_port_listener_int({Port, WorkerSpawner, ListenOptions, AcceptorsNumber}).

-spec remove_port_listener(port_identifier()) -> ok | {error, term()}.
remove_port_listener(Port) ->
    supervisor:terminate_child(?MODULE, Port),
    supervisor:delete_child(?MODULE, Port).

-spec change_port_acceptors_number(port_identifier(), non_neg_integer()) -> ok.
change_port_acceptors_number(Port, NewAcceptors) when is_integer(NewAcceptors), NewAcceptors >= 0 ->
    tcpserver_listener:set_acceptors_num(child_pid(Port), NewAcceptors).

-spec get_socket_from_child(port_identifier()) -> gen_tcp:socket().
get_socket_from_child(Port) ->
    tcpserver_listener:get_socket_from_child(child_pid(Port)).


%%====================================================================
%% Application API
%%====================================================================

start(_StartType, _StartArgs) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_State) ->
    ok.


%%====================================================================
%% Supervisor callbacks
%%====================================================================

init(_) ->
    StartupListeners = application:get_env(?APP, startup_listeners, []),
    ProvidedSupervisorFlags = application:get_env(?APP, supervisor_flags, #{}),
    FinalSupervisorFlags = maps:merge(ProvidedSupervisorFlags, #{strategy => one_for_one}),

    {ok, { FinalSupervisorFlags, [ child_spec(Listener) || Listener <- StartupListeners ]}}.


%%====================================================================
%% Internal functions
%%====================================================================

add_port_listener_int(ChildSpecArgs) ->
    application:ensure_all_started(?APP),
    supervisor:start_child(?MODULE, child_spec(ChildSpecArgs)).

child_spec({Port, WorkerSpawner}) ->
    child_spec({Port, WorkerSpawner, []});
child_spec({Port, WorkerSpawner, ListenOptions}) when is_list(ListenOptions) ->
    child_spec({Port, WorkerSpawner, ListenOptions, ?DEFAULT_SOCKET_ACCEPTORS});
child_spec({Port, WorkerSpawner, AcceptorsNumber}) when is_integer(AcceptorsNumber), AcceptorsNumber > 0 ->
    child_spec({Port, WorkerSpawner, [], AcceptorsNumber});
child_spec({Port, WorkerSpawner, ListenOptions, AcceptorsNumber}) ->
    #{id => Port,
      start => {tcpserver_listener, start_link, [Port, WorkerSpawner, ListenOptions, AcceptorsNumber]},
      % restart => permanent,
      shutdown => infinity,
      type => worker
      % modules => [tcpserver_listener]
     }.

child_pid(Port) ->
    hd([ Pid || {ListenPort, Pid, _, _} <- supervisor:which_children(?MODULE), ListenPort == Port ]).

