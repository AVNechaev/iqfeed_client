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
-export([start_link/3, set_instrs/1]).

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

-define(SERVER, ?MODULE).

-define(RECONNECT_TIMEOUT, 500).
-define(HANDSHAKE, <<"S,SET PROTOCOL,5.1", 10, 13>>).

-compile([{parse_transform, lager_transform}]).
%%%===================================================================
%%% API
%%%===================================================================
-spec(start_link(IP :: string(), Port :: non_neg_integer(), Instrs :: [string() | binary()]) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(IP, Port, Instrs) -> gen_server:start_link({local, ?SERVER}, ?MODULE, [IP, Port, Instrs], []).

%%--------------------------------------------------------------------
-spec set_instrs(Instrs :: [instr_name()]) -> ok.
set_instrs(Instrs) -> gen_server:call(?SERVER, {set_instrs, Instrs}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([IP, Port, Instrs]) ->
  gen_server:cast(self(), connect),
  {ok, #state{ip = IP, port = Port, instrs = Instrs}}.

%%--------------------------------------------------------------------
handle_cast(connect, State = #state{ip = IP, port = Port, sock = S}) when S =:= undefined->
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
      gen_server:cast(self(), connect),
      {noreply, State}
  end.

%%--------------------------------------------------------------------
handle_info({tcp_error, _S, Reason}, State) ->
  lager:warning("IQFeed Level 1 connection lost due to: ~p", [Reason]),
  gen_server:cast(self(), connect),
  {noreply, State = #state{sock = undefined}};
%%---
handle_info({tcp_closed, _S}, State) ->
  {noreply, State};
%%---
handle_info({tcp, _S, Data}, State) ->
  lager:info("IQFL1 got data: ~p", [Data]),
  {noreply, State}.

%%--------------------------------------------------------------------
handle_call({set_instrs, Instrs}, _From, State) ->
  lager:info("Loading additional instruments to IQFeed [~p]...", [erlang:length(Instrs)]),
  case State#state.sock of
    undefined -> ok;
    Sock -> init_instrs(Sock, Instrs)
  end,
  lager:info("Instruments are loaded."),
  NewInstrs = Instrs ++ State#state.instrs,
  {reply, ok, State#state{instrs = NewInstrs}}.

%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_instrs(Socket, Instrs) ->
  lists:foreach(fun(I) -> ok = gen_tcp:send(Socket, [<<"t">>, I, 13, 10]) end, Instrs).