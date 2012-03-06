#!/bin/bash
ERL_LIBS=deps erl -pa ebin -I include -run gateway_app -sname gateway -detached -config cloud
