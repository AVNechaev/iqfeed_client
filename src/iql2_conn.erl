%%%-------------------------------------------------------------------
%%% @author user
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11. Июль 2016 19:55
%%%-------------------------------------------------------------------
-module(iql2_conn).
-author("user").

-behaviour(gen_server).

%% API
-export([start_link/0, get_history/3]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-include("iqfeed_client.hrl").

-type on_history_data() :: {data, {TimeUTC :: non_neg_integer(), #candle{}}} | end_of_data | {error, Reason :: any()}.
-type on_history_fun() :: fun((Data :: on_history_data()) -> ok).

-type get_history_reply() :: ok | {error, not_connected} | {error, getting_data}.

-record(curr_req, {
  instr :: instr_name(),
  hist_fun :: on_history_fun()
}).

-record(state, {
  ip :: string(),
  port :: non_neg_integer(),
  sock = undefined :: undefined | gen_tcp:socket(),
  shift_to_utc :: integer(),
  req = undefined :: undefined | #curr_req{}
}).

-define(RECONNECT_TIMEOUT, 500).
-define(HANDSHAKE, <<"S,SET PROTOCOL,5.1", 10, 13>>).
-define(SHIFT_TO_UTC_TIMEOUT, 10000).

-compile([{parse_transform, lager_transform}]).
%%%===================================================================
%%% API
%%%===================================================================
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
-spec get_history(Instr :: instr_name(), Depth :: non_neg_integer(), OnData :: on_history_fun()) -> get_history_reply().
get_history(Instr, Depth, OnData) -> gen_server:call(?SERVER, {get_history, Instr, Depth, OnData}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  gen_server:cast(self(), connect),

  Timezone = rz_util:get_env(iqfeed_client, timezone),
  DT = localtime:utc_to_local(erlang:universaltime(), Timezone),
  LocalSeconds = calendar:datetime_to_gregorian_seconds(DT),
  UTCSeconds = calendar:datetime_to_gregorian_seconds(localtime:local_to_utc(DT, Timezone)),
  Shift = UTCSeconds - LocalSeconds,
  erlang:start_timer(?SHIFT_TO_UTC_TIMEOUT, self(), check_shift_to_utc),
  {ok, #state{
    ip = rz_util:get_env(iqfeed_client, iqfeed_ip),
    port = rz_util:get_env(iqfeed_client, iqfeed_l2port),
    shift_to_utc = Shift
  }}.

%%--------------------------------------------------------------------
handle_cast(connect, State = #state{ip = IP, port = Port, sock = S}) when S =:= undefined ->
  SockOpts = [
    {active, true},
    {delay_send, false},
    {mode, binary},
    binary,
    {packet, line}
  ],
  lager:info("Connecting to IQFeed Level 2 port at ~p:~p...", [IP, Port]),
  case gen_tcp:connect(IP, Port, SockOpts) of
    {ok, Sock} ->
      lager:info("IQFeed Level 2 connection established"),
      gen_tcp:send(Sock, ?HANDSHAKE),
      {noreply, State#state{sock = Sock}};
    {error, Reason} ->
      lager:warning("IQFeed Level 2: couldn't connect due to: ~p", [Reason]),
      timer:sleep(?RECONNECT_TIMEOUT),
      gen_server:cast(self(), connect),
      {noreply, State}
  end.

%%--------------------------------------------------------------------
handle_info({timeout, _, check_shift_to_utc}, State) ->
  Shift = iql1_conn:get_shift_to_utc(),
  erlang:start_timer(?SHIFT_TO_UTC_TIMEOUT, self(), check_shift_to_utc),
  {noreply, State#state{shift_to_utc = Shift}};
%%---
handle_info({tcp_error, _S, Reason}, State) ->
  lager:warning("IQFeed Level 2 connection lost due to: ~p", [Reason]),
  gen_server:cast(self(), connect),
  {noreply, State#state{sock = undefined}};
%%---
handle_info({tcp_closed, _S}, State) ->
  {noreply, State};
%%---
handle_info({tcp, _S, Data}, State = #state{req = CR}) when CR == undefined ->
  lager:info("Got Msg: ~p", [Data]),
  {noreply, State};
%%---
handle_info({tcp, _S, Data}, State) ->
  {ok, NewState} = process_data(Data, State),
  {noreply, NewState}.

%%--------------------------------------------------------------------
handle_call({get_history, _, _, _}, _From, State = #state{sock = undefined}) ->
  {reply, {error, not_connected}, State};
handle_call({get_history, _, _, _}, _From, State = #state{req = CR}) when CR =/= undefined ->
  {reply, {error, getting_data}, State};
handle_call({get_history, Instr, Depth, OnData}, _From, State = #state{sock = Sock}) ->
  Data = [
    <<"HDT,">>,
    Instr, <<",">>,                     %symbol
    get_date(0, State), <<",">>,               %begindate
    get_date(Depth, State), <<",">>,           %enddate
    integer_to_binary(Depth), <<",">>,  %maxdatapoints
    <<"1,">>,                           %datadirection
    <<",">>,                            %requestid
    10, 13                              %datapointspersend
  ],
  gen_tcp:send(Sock, Data),
  Req = #curr_req{instr = Instr, hist_fun = OnData},
  {reply, ok, State#state{req = Req}}.

%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
process_data(<<"!ENDMSG!">>, State) ->
  ((State#state.req)#curr_req.hist_fun)(end_of_data),
  lager:info("Request finished."),
  {ok, State#state{req = undefined}};
process_data(Data, State) ->
  S = binary:split(Data, <<",">>, [global]),
  try
    Candle = #candle{
      name = (State#state.req)#curr_req.instr,
      high = binary_to_float(lists:nth(2, S)),
      low = binary_to_float(lists:nth(3, S)),
      open = binary_to_float(lists:nth(4, S)),
      close = binary_to_float(lists:nth(5, S)),
      vol = binary_to_integer(lists:nth(6, S))
    },
    ((State#state.req)#curr_req.hist_fun)({data, {bin2time(lists:nth(1, S), State), Candle}}),
    {ok, State}
  catch
    M:E ->
      lager:warning("Unexpected L1 update msg: ~p; error: ~p:~p", [Data, M, E]),
      {ok, State}
  end.

%%--------------------------------------------------------------------
get_date(DepthIn, State) ->
  Ct = calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
  {{Y, M, D}, _} = calendar:gregorian_seconds_to_datetime(Ct - State#state.shift_to_utc - (DepthIn * 60 * 60 * 24)),
  io_lib:format("~4.10.0B~2.10.0B~2.10.0B", [Y, M, D]).

%%--------------------------------------------------------------------
bin2time(<<Y:4/binary, $-, M:2/binary, $-, D:2/binary, $ , H:2/binary, Mi:2/binary, S:2/binary>>, State) ->
  DT = {
    {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
    {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)}},
  calendar:datetime_to_gregorian_seconds(DT) + State#state.shift_to_utc.