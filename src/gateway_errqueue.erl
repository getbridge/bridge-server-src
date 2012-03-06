% Node-Global Errqueue that keeps track of unroutable messages.

% THIS MODULE IS CURRENTLY DISABLED

-module(gateway_errqueue).
-export([loop/1]).
-include_lib("amqp_client/include/amqp_client.hrl").

loop(Channel) ->
    receive
        #'basic.consume_ok'{} ->
            gateway_util:info("ERROR QUEUE Beginning consumption~n"),
            loop(Channel);

        %% This is received when the subscription is cancelled
        #'basic.cancel_ok'{} ->
            gateway_util:info("ERROR QUEUE Subscription cancelled~n"),
            exit(normal),
            ok;

        {#'basic.deliver'{delivery_tag = Tag, routing_key = Key, exchange = Exchange}, Content} ->
            %% Do something with the message payload
            %% (some work here)
            #amqp_msg{payload = Payload, props = #'P_basic'{headers = Headers}} = Content,
            gateway_util:info("ERROR QUEUE AMQP message ~s: ~s from ~s headers ~p~n", [Key, Payload, Exchange, Headers]),

            amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),

            %% Loop
            loop(Channel);
        X ->
            gateway_util:info("ERROR QUEUE UNKNOWN ~p~n", [X]),
            loop(Channel)
    end.
