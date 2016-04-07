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
-export([start_link/4, set_instrs/1, get_instrs/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-include("iqfeed_client.hrl").

-record(state, {
  ip :: string(),
  port :: non_neg_integer(),
  instrs = [] :: [instr_name()], %% список акций, по которым запрашиваются тики
  sock = undefined :: undefined | gen_tcp:socket(),
  tick_fun :: tick_fun(),
  timezone :: string(),
  current_day :: calendar:date()
}).

-define(SERVER, ?MODULE).

-define(RECONNECT_TIMEOUT, 500).
-define(HANDSHAKE, <<"S,SET PROTOCOL,5.1", 10, 13>>).

-compile([{parse_transform, lager_transform}]).
%%%========================================================io_lib:format===========
%%% API
%%%===================================================================
-spec(start_link(
    TickFun :: tick_fun(),
    IP :: string(),
    Port :: non_neg_integer(),
    Instrs :: [string() | binary()]) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(TickFun, IP, Port, Instrs) -> gen_server:start_link({local, ?SERVER}, ?MODULE, [TickFun, IP, Port, Instrs], []).

%%--------------------------------------------------------------------
-spec set_instrs(Instrs :: [instr_name()]) -> {Added :: non_neg_integer(), Duplicates :: non_neg_integer()}.
set_instrs(Instrs) -> gen_server:call(?SERVER, {set_instrs, Instrs}, infinity).

%%--------------------------------------------------------------------
-spec get_instrs() -> [instr_name()].
get_instrs() -> gen_server:call(?SERVER, get_instrs, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([TickFun, IP, Port, Instrs]) ->
  gen_server:cast(self(), connect),
  Timezone = iqfeed_util:get_env(iqfeed_client, timezone),
  {Day, _} = localtime:utc_to_local(erlang:universaltime(), Timezone),
  {ok, #state{
    tick_fun = TickFun,
    ip = IP,
    port = Port,
    instrs = lists:usort(Instrs),
    timezone = Timezone,
    current_day = Day
  }}.

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
  {ok, NewState} = process_data(Data, State),
  {noreply, NewState}.

%%--------------------------------------------------------------------
handle_call({set_instrs, Instrs}, _From, State) ->
  UniqInstrs = lists:usort(Instrs),
  lager:info(
    "Loading additional instruments to IQFeed [~p]; unique:~p...",
    [erlang:length(Instrs), erlang:length(UniqInstrs)]),
  CurInstrsCnt = erlang:length(State#state.instrs),
  NewInstrs = lists:umerge(State#state.instrs, UniqInstrs),
  Added = erlang:length(NewInstrs) - CurInstrsCnt,
  Duplicates = erlang:length(Instrs) - Added,
  case State#state.sock of
    undefined -> ok;
    Sock -> init_instrs(Sock, NewInstrs)
  end,
  lager:info("Instruments are loaded."),
  {reply, {Added, Duplicates}, State#state{instrs = NewInstrs}};
%%---
handle_call(get_instrs, _From, State) -> {reply, State#state.instrs, State}.

%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_instrs(Socket, Instrs) ->
  lists:foreach(fun(I) -> ok = gen_tcp:send(Socket, [<<"t">>, I, 13, 10]) end, Instrs).

%%--------------------------------------------------------------------
-spec process_data(Data :: binary(), State :: #state{}) -> ok.
process_data(AllData = <<"Q,", Data/binary>>, State) ->
  S = binary:split(Data, <<",">>, [global]),
  try
    Tick = #tick{
      name = lists:nth(1, S),
      last_price = binary_to_float(lists:nth(2, S)),
      last_vol = binary_to_integer(lists:nth(3, S)),
      time = bin2time(lists:nth(4, S), State),
      bid = binary_to_float(lists:nth(7, S)),
      ask = binary_to_float(lists:nth(9, S))
    },
    case lists:nth(15, S) of
      <<"C">> -> (State#state.tick_fun)(Tick);
      _ -> ok
    end
  catch
    M:E ->
      lager:warning("Unexpected L1 update msg: ~p; error: ~p:~p", [AllData, M, E])
  end,
  {ok, State};
%%---
process_data(<<"T,", Y:4/binary, M:2/binary, D:2/binary, " ", _/binary>>, State) ->
  {ok, State#state{current_day = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)}}};
%%---
process_data(Data, State) ->
  lager:debug("IQFeed Level 1 message: ~p", [Data]),
  {ok, State}.

%%--------------------------------------------------------------------
-spec bin2time(B :: binary(), CurrentDay :: calendar:date()) -> pos_integer().
bin2time(<<H:2/binary, $:, M:2/binary, $:, S:2/binary, _/binary>>, State) ->
  DateTime = {State#state.current_day, {binary_to_integer(H), binary_to_integer(M), binary_to_integer(S)}},
  calendar:datetime_to_gregorian_seconds(localtime:local_to_utc(DateTime, State#state.timezone)).
