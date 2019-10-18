-module(ranch_socket).
-behaviour(ranch_transport).

-export([name/0]).
-export([secure/0]).
-export([messages/0]).
-export([listen/1]).
-export([disallowed_listen_options/0]).
-export([accept/2]).
-export([handshake/2]).
-export([handshake/3]).
-export([handshake_continue/2]).
-export([handshake_continue/3]).
-export([handshake_cancel/1]).
-export([connect/3]).
-export([connect/4]).
-export([recv/3]).
-export([recv_proxy_header/2]).
-export([send/2]).
-export([sendfile/2]).
-export([sendfile/4]).
-export([sendfile/5]).
-export([setopts/2]).
-export([getopts/2]).
-export([getstat/1]).
-export([getstat/2]).
-export([controlling_process/2]).
-export([peername/1]).
-export([sockname/1]).
-export([shutdown/2]).
-export([close/1]).

-type opt() :: {domain, socket:domain()}
	| {addr, any | broadcast | loopback | socket:sockaddr()}.
-export_type([opt/0]).

-type opts() :: [opt()].
-export_type([opts/0]).

-spec name() -> socket.
name() -> socket.

-spec secure() -> boolean().
secure() ->
	false.

-spec messages() -> {tcp, tcp_closed, tcp_error, tcp_passive}.
messages() -> {tcp, tcp_closed, tcp_error, tcp_passive}.

-spec listen(ranch:transport_opts(opts())) -> {ok, socket:socket()} | {error, atom()}.
listen(TransOpts) ->
	SocketOpts = maps:get(socket_opts, TransOpts, []),
	{domain, Domain} = lists:keyfind(domain, 1, SocketOpts),
	Type = stream,
	Protocol = tcp,
	{addr, Addr} = lists:keyfind(addr, 1, SocketOpts),
	case socket:open(Domain, Type, Protocol) of
		OK={ok, Socket} ->
			%% docs seem to be incorrect here, bind really returns an 'ok' _tuple_, not just 'ok'
			%% -> investigate later
			_ = socket:bind(Socket, Addr),
			ok = socket:listen(Socket),
			OK;
		Error={error, _} ->
			Error
	end.

-spec disallowed_listen_options() -> [atom()].
disallowed_listen_options() ->
	[].

-spec accept(socket:socket(), timeout())
	-> {ok, socket:socket()} | {error, closed | timeout | atom()}.
accept(LSocket, Timeout) ->
	socket:accept(LSocket, Timeout).

-spec handshake(inet:socket(), timeout()) -> {ok, socket:socket()}.
handshake(CSocket, Timeout) ->
	handshake(CSocket, [], Timeout).

-spec handshake(socket:socket(), opts(), timeout()) -> {ok, socket:socket()}.
handshake(CSocket, _, _) ->
	{ok, CSocket}.

-spec handshake_continue(socket:socket(), timeout()) -> no_return().
handshake_continue(CSocket, Timeout) ->
	handshake_continue(CSocket, [], Timeout).

-spec handshake_continue(socket:socket(), opts(), timeout()) -> no_return().
handshake_continue(_, _, _) ->
	error(not_supported).

-spec handshake_cancel(socket:socket()) -> no_return().
handshake_cancel(_) ->
	error(not_supported).

%% @todo Probably filter Opts?
-spec connect(inet:ip_address() | inet:hostname(),
	inet:port_number(), any())
	-> {ok, inet:socket()} | {error, atom()}.
connect(Host, Port, Opts) when is_integer(Port) ->
	gen_tcp:connect(Host, Port,
		Opts ++ [binary, {active, false}, {packet, raw}]).

%% @todo Probably filter Opts?
-spec connect(inet:ip_address() | inet:hostname(),
	inet:port_number(), any(), timeout())
	-> {ok, inet:socket()} | {error, atom()}.
connect(Host, Port, Opts, Timeout) when is_integer(Port) ->
	gen_tcp:connect(Host, Port,
		Opts ++ [binary, {active, false}, {packet, raw}],
		Timeout).

-spec recv(socket:socket(), non_neg_integer(), timeout())
	-> {ok, any()} | {error, closed | atom()}.
recv(Socket, Length, Timeout) ->
	socket:recv(Socket, Length, Timeout).

-spec recv_proxy_header(inet:socket(), timeout())
	-> {ok, ranch_proxy_header:proxy_info()}
	| {error, closed | atom()}
	| {error, protocol_error, atom()}.
recv_proxy_header(Socket, Timeout) ->
	case recv(Socket, 0, Timeout) of
		{ok, Data} ->
			case ranch_proxy_header:parse(Data) of
				{ok, ProxyInfo, <<>>} ->
					{ok, ProxyInfo};
				{ok, ProxyInfo, Rest} ->
					case gen_tcp:unrecv(Socket, Rest) of
						ok ->
							{ok, ProxyInfo};
						Error ->
							Error
					end;
				{error, HumanReadable} ->
					{error, protocol_error, HumanReadable}
			end;
		Error ->
			Error
	end.

-spec send(socket:socket(), iodata()) -> ok | {error, atom()}.
send(Socket, Packet) ->
	socket:send(Socket, Packet).

-spec sendfile(inet:socket(), file:name_all() | file:fd())
	-> {ok, non_neg_integer()} | {error, atom()}.
sendfile(Socket, Filename) ->
	sendfile(Socket, Filename, 0, 0, []).

-spec sendfile(inet:socket(), file:name_all() | file:fd(), non_neg_integer(),
		non_neg_integer())
	-> {ok, non_neg_integer()} | {error, atom()}.
sendfile(Socket, File, Offset, Bytes) ->
	sendfile(Socket, File, Offset, Bytes, []).

-spec sendfile(inet:socket(), file:name_all() | file:fd(), non_neg_integer(),
		non_neg_integer(), [{chunk_size, non_neg_integer()}])
	-> {ok, non_neg_integer()} | {error, atom()}.
sendfile(Socket, Filename, Offset, Bytes, Opts)
		when is_list(Filename) orelse is_atom(Filename)
		orelse is_binary(Filename) ->
	case file:open(Filename, [read, raw, binary]) of
		{ok, RawFile} ->
			try sendfile(Socket, RawFile, Offset, Bytes, Opts) of
				Result -> Result
			after
				ok = file:close(RawFile)
			end;
		{error, _} = Error ->
			Error
	end;
sendfile(Socket, RawFile, Offset, Bytes, Opts) ->
	Opts2 = case Opts of
		[] -> [{chunk_size, 16#1FFF}];
		_ -> Opts
	end,
	try file:sendfile(RawFile, Socket, Offset, Bytes, Opts2) of
		Result -> Result
	catch
		error:{badmatch, {error, enotconn}} ->
			%% file:sendfile/5 might fail by throwing a
			%% {badmatch, {error, enotconn}}. This is because its
			%% implementation fails with a badmatch in
			%% prim_file:sendfile/10 if the socket is not connected.
			{error, closed}
	end.

%% @todo Probably filter Opts?
-spec setopts(inet:socket(), list()) -> ok | {error, atom()}.
setopts(Socket, Opts) ->
	inet:setopts(Socket, Opts).

-spec getopts(inet:socket(), [atom()]) -> {ok, list()} | {error, atom()}.
getopts(Socket, Opts) ->
	inet:getopts(Socket, Opts).

-spec getstat(inet:socket()) -> {ok, list()} | {error, atom()}.
getstat(Socket) ->
	inet:getstat(Socket).

-spec getstat(inet:socket(), [atom()]) -> {ok, list()} | {error, atom()}.
getstat(Socket, OptionNames) ->
	inet:getstat(Socket, OptionNames).

-spec controlling_process(socket:socket(), pid())
	-> ok.
controlling_process(_, _) ->
	ok.

-spec peername(socket:socket())
	-> {ok, term()} | {error, atom()}.
peername(Socket) ->
	socket:peername(Socket).

-spec sockname(socket:socket())
	-> {ok, term()} | {error, atom()}.
sockname(Socket) ->
	socket:sockname(Socket).

-spec shutdown(socket:socket(), read | write | read_write)
	-> ok | {error, atom()}.
shutdown(Socket, How) ->
	socket:shutdown(Socket, How).

-spec close(socket:socket()) -> ok.
close(Socket) ->
	socket:close(Socket).
