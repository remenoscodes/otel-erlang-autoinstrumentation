-module(items_handler).
-export([init/2]).

%% Hand-rolled JSON body: keeping this app dependency-free (no jsx/jason)
%% is part of the point — this is as vanilla and minimal as a Cowboy
%% service gets.
init(Req0, State) ->
    Body = <<"{\"count\":3,\"items\":[\"alpha\",\"beta\",\"gamma\"]}">>,
    Req = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req0),
    {ok, Req, State}.
