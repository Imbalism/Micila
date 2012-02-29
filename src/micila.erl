-module(micila).
-export([handle_http/1, handle_websocket/1]).
-define(LOCATION, local).

handle_http(Req) ->
    handle(Req:get(method), Req:resource([lowercase, urldecode]), Req).


handle('GET', [], Req) ->
    erlydtl:compile("./static/index.html", index),
    {ok, Index} = index:render([]),
    Req:ok(Index);
handle('POST', ["chat"], Req) ->
    case ?LOCATION of
	local ->
	    {ok, [{addr, Addr}]} = inet:ifget("wlan0", [addr]);
	remote ->
	    Addr = {23,20,58,119};
	_UNDEFINED ->
	    {ok, [{addr, Addr}]} = inet:ifget("wlan0", [addr])
    end,
    Args = Req:parse_qs(),
    case proplists:get_value("email", Args) of
	undefined -> Email = "auto";
	Email -> true
    end,
    case proplists:get_value("channel", Args) of
	undefined -> Channel = "auto";
	Channel -> true
    end,
    erlydtl:compile("./template/chat.html", chat),
    {ok, Chat} = chat:render([
			      {title, "Micila-0.2"},
			      {ip, inet_parse:ntoa(Addr)},
			      {email, Email},
			      {channel, Channel}
			     ]),
    Req:ok([Chat]).

waitForEmailAndSex()->
    receive
	{browser, Data} ->
	    [_, _, Email, Sex] = re:split(Data, "/"),
	    {Email, Sex};
	Other -> io:format("wrong register ~p~n", [Other])
    end.

handle_websocket(Ws) ->
    {Email, Sex} = waitForEmailAndSex(),
    io:format("waiting for room assignment~n"),
    {Room, welcome, {id, ID}} = remote:rpc(manager, {join, {Email, Sex}}),
    Ws:send(["/joined/" , integer_to_list(ID)]),
    handle_websocket(Ws, ID, Room).

handle_websocket(Ws, ID, Room) ->
    receive
	{browser, Data} ->
	    case re:run(Data, "^/(?<CMD>.*?)/\n?(?<ARG>.*)", [dotall, {capture, ['CMD','ARG'], list}]) of
		{match, [CMD, ARG]}->
		    case list_to_atom(CMD) of
			say->
			    Room ! {say, ID, ARG};
			status ->
			    Room ! {update, ID, list_to_atom(ARG)};
			choice ->
			    Room ! {choice, ID, list_to_integer(ARG)}
		    end,
		    handle_websocket(Ws, ID, Room);
		nomatch->
		    io:format("unknown command:~p~n",[Data]),
		    closed
	    end;
	{say, SID, DATA} ->
	    Ws:send(["/say/", integer_to_list(SID), "/", DATA]),
	    handle_websocket(Ws, ID, Room);
	{system, CMD, ARG} ->
	    case CMD of
		started->
		    Ws:send(["/say/",
			     "sys",
			     "/",
			     "The door has closed! Let's chat!"]),
		    Ws:send(["/event/",
			     "started/",
			     integer_to_list(ARG)
			     ]),
		    handle_websocket(Ws, ID, Room);	    
		pair->
		    {{A, EmailA, SexA}, {B, EmailB, SexB}} = ARG,
		    if
			A == ID ->
			    Ws:send(["/event/",
				     "info/",
				     integer_to_list(B),
				     "/",
				     EmailB,
				     "/",
				     SexB]
				   );
			B == ID ->
			    Ws:send(["/event/",
				     "info/",
				     integer_to_list(A),
				     "/",
				     EmailA,
				     "/",
				     SexA]
				   );
			true -> true
		    end,
		    Ws:send(["/event/",
			    "paired/",
			    integer_to_list(A),
			    "/",
			    integer_to_list(B)]
			   ),
		    handle_websocket(Ws, ID, Room);	    		
		endSel->
		    Ws:send(["/event/",
			    "end"
			     ]
			   ),
		    case ARG of
			false ->
			    Ws:send(["/say/",
				     "sys/",
				     "no pair matched, what a pity!"
				    ]
			   );
			true -> ok
		    end;
		_ -> handle_websocket(Ws, ID, Room)
	    end;
	{update, SID, Status} ->
	    case Status of
		offline->
		    Color = "offline";
		online ->
		    Color = "<font color='blue'>online";
		away ->
		    Color = "<font color='yellow'>away"
	    end,
	    Ws:send(["/status/", integer_to_list(SID), "/", Color]),
	    handle_websocket(Ws, ID, Room);
	closed ->
	    io:format("user exited~n"),
	    Room ! {update, ID, offline}, 
	    Room ! {self(), closed, ID};
	Other ->
	    io:format("unknown command!~p~n", [Other]),
	    handle_websocket(Ws, ID, Room)
    end.
