# Bridge Server
Bridge is a unified messaging system that allows you to easily build
cross-language services to share data and realtime updates among your
servers and your clients

## Runtime Requirements
The Bridge Server requires Erlang (>= R14B) and rebar (included in this
directory).

## Installation
Before compiling for the first time, you must use rebar to resolve
dependencies.

    ./rebar get-deps

To compile the Bridge Server, run the following from the top level
directory of this project:

    ./rebar compile 

Finally to run the Bridge Server in development mode, start RabbitMQ and
then run:

    ./scripts/run-verbose.sh


## Documentation and Support
* API Reference: http://www.getbridge.com/docs/api/js/
* Getting Started: http://www.getbridge.com/docs/gettingstarted/js/
* About Bridge: http://www.getbridge.com/

The `examples` directory of this library contains sample applications for Bridge.

Support is available in #getbridge on Freenode IRC or the Bridge Google Group.


## License
Bridge is made available under the MIT/X11 license. See LICENSE file for details.
