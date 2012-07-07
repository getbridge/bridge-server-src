%% @copyright 2012 Flotype Inc.
%% @author Sridatta Thatipamala
%% @doc Methods to manipulate Bridge references

-module(gateway_reference).
-compile([export_all]).

%% API

client_reference(ClientId, ObjectId) ->
  PathChain = [ <<"client">>, ClientId, ObjectId],
  gateway_util:binpathchain_to_nowref(PathChain).


service_reference(ServiceId, ObjectId) ->
  PathChain = [<<"named">>, ServiceId, ObjectId],
  gateway_util:binpathchain_to_nowref(PathChain).


get_object_id(Reference) ->
  PathChain = gateway_util:extract_binpathchain_from_nowref(Reference),
  lists:nth(3, PathChain).


get_destination_id(Reference) ->
  PathChain = gateway_util:extract_binpathchain_from_nowref(Reference),
  lists:nth(2, PathChain).


set_method(Reference, Method) ->
  ThreePartChain = gateway_util:extract_binpathchain_from_nowref(Reference),
  FourPartChain  = lists:append(ThreePartChain, [Method]),
  gateway_util:binpathchain_to_nowref(FourPartChain).
