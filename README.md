# tcpserver

Simple (3 modules) erlang tcp server application to use as dependency for my projects.  
You may want to check [ranch](https://github.com/ninenines/ranch).

## How to use:

Include it as a dependency, and from your code, call:

```
    SupervisorReturn = tcpserver:add_port_listener(Port, SpawnWorker, Options, NumAcceptors),
```
(Only `Port` and `SpawnWorker` are mandatory)

Listeners are identified by the `Port`, if it's an integer, that number is passed
to the underlying gen_tcp listen call, if not, it will listen in a random port
and use `Port` as listener identifier.  
(The port can be retrieved from the socket returned from
`tcpserver:get_socket_from_child/1`, please notice that the port will change if
the listener process is restarted)


`SpawnWorker` is used to obtain the worker Pid for each connection. The following are
supported:
* `{M, F, A}`: `apply(M, F, A ++ [AcceptedSocket])` will be called
* `{M, F}`: Same as the previous, but with `A = []`
* `M`: Same as previous, but with `F = create_worker`
* `fun(AcceptedSocket)`: It will be called as it is.

`Options` are the usual `gen_tcp:listen` options plus `{notify_socket_transfer,
boolean()}`, which will send a `{socket_is_yours, AcceptedSocket}` message to
the worker Pid once the socket transfer has been completed.

`NumAcceptors` is the number of processes in the accept queue. It can be changed
using `tcpserver:change_port_acceptors_number/2`

## Application env vars

The application will read `supervisor_flags` to complete the supervisor spec.  
It will accept a list in `startup_listeners` with tuples like `{Port,
SpawnWorker, Options, NumAcceptors}`  


## Caveats

Workers MUST link to the AcceptedSocket to receive the socket shutdown
should an error happen before transferring the control of the socket (such as
premature close) is completed.  
If workers rely on the `notify_socket_transfer`, they SHOULD link to the acceptor's
Pid (retrieved by self() in the callback) to handle the possible kill between
the `controlling_process` call and the `socket_is_yours` message

## TODO:

Add `-spec` everywhere `'-.-`

## Run tests:
```
rebar3 ct
```

## Authors

* **Jose M Perez Ramos** - [Kuroneer](https://github.com/Kuroneer)

## License

[MIT License](LICENSE)

