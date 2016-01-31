%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 31. Jan 2016 22:24
%%%-------------------------------------------------------------------
-module(iql1_conn).
-author("anechaev").

-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-type(instr_name() :: string() | binary()).
-export_type([instr_name/0]).

-record(state, {
  ip :: string(),
  port :: non_neg_integer(),
  instrs = [] :: [instr_name()], %% список акций, по которым запрашиваются тики
  sock = undefined :: undefined | gen_tcp:socket()
}).
-compile([{parse_transform, lager_transform}]).

-define(RECONNECT_TIMEOUT, 500).
-define(HANDSHAKE, <<"S,SET PROTOCOL,5.1", 10, 13>>).
%%%===================================================================
%%% API
%%%===================================================================
-spec(start_link(IP :: string(), Port :: non_neg_integer(), Instrs :: [string() | binary()]) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(IP, Port, Instrs) -> gen_server:start_link(?MODULE, [IP, Port, Instrs], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([IP, Port, Instrs]) ->
  gen_server:cast(self(), connect),
  {ok, #state{ip = IP, port = Port, instrs = Instrs}}.

%%--------------------------------------------------------------------
handle_cast(connect, State = #state{ip = IP, port = Port}) ->
  SockOpts = [
    {active, true},
    {delay_send, false},
    {mode, binary},
    binary,
    {packet, line}
  ],
  lager:info("Connecting to IQFeed Level 1 port at ~p:~p...", [IP, Port]),
  case gen_tcp:connect(IP, Port, SockOpts) of
    {ok, Sock} ->
      lager:info("IQFeed Level 1 connection established"),
      gen_tcp:send(Sock, ?HANDSHAKE),
      init_instrs(Sock, State#state.instrs),
      {noreply, State#state{sock = Sock}};
    {error, Reason} ->
      lager:warning("IQFeed Level 1: couldn't connect due to: ~p", [Reason]),
      timer:sleep(?RECONNECT_TIMEOUT),
      gen_server:cast(self, connect),
      {noreply, State}
  end.

%%--------------------------------------------------------------------
handle_info({tcp_error, _S, Reason}, State) ->
  lager:warning("IQFeed Level 1 connection lost due to: ~p", [Reason]),
  gen_server:cast(self(), connect),
  {noreply, State};
handle_info({tcp, _S, Data}, State) ->
  lager:info("IQFL1 got data: ~p", [Data]),
  {noreply, State}.

%%--------------------------------------------------------------------
handle_call(_Request, _From, _State) -> exit(handle_call_unsupported).

%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_instrs(Socket, Instrs) ->
  lists:foreach(fun(I) -> gen_tcp:send(Socket, [<<"t">>, I, 10, 13]) end, Instrs).