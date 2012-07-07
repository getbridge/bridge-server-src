%% @copyright 2012 Flotype Inc.
%% @author Sridatta Thatipamala

%% @doc Generates and sends standard error messages

-module(gateway_error).
-compile([export_all]).

%% API

no_publish_perms() ->
  gen_server:cast(self(), {error, 102, "Publish service permissions denied"}).

invalid_service_name(Name) ->
  gen_server:cast(self(), {error, 103, <<"Invalid service name: ", Name/binary>>}).

no_unpublish_perms() ->
  gen_server:cast(self(), {error, 113, "Unpublish service permissions denied"}).

no_join_perms() ->
  gen_server:cast(self(), {error, 104, "Join channel permissions denied"}).

invalid_channel_name(Name) ->
  gen_server:cast(self(), {error, 105, <<"Invalid channel name: ", Name/binary>>}).

no_getchannel_perms() ->
  gen_server:cast(self(),  {error, 106, "Get channel permissions denied"}).

no_leavechannel_perms() ->
  gen_server:cast(self(), {error, 108, "Leave channel permissions denied"}).

system_service() ->
  gen_server:cast(self(), {error, 111, "System service calls are not allowed"}).

no_valid_api_key() ->
  gen_server:cast(self(), {error, 220, "No valid api key provided."}).
