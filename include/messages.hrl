%% @doc Records representing Bridge message types

-define(jwp_fields, { name, callback}).
-record(join_workerpool, ?jwp_fields).

-define(lwp_fields, {name, callback}).
-record(leave_workerpool, ?lwp_fields).

-define(get_ops_fields, { client, name, callback}).
-record(get_ops, ?get_ops_fields).

-define(jc_fields, { name, handler, callback, writeable}).
-record(join_channel, ?jc_fields).

-define(lc_fields, {name, handler, callback}).
-record(leave_channel, ?lc_fields).

-define(gc_fields, {name, callback}).
-record(get_channel, ?gc_fields).

-define(send_fields, {destination, args}).
-record(send, ?send_fields).

-define(connect_fields, {session, api_key}).
-record(connect, ?connect_fields).
