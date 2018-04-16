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
-export([start_link/4, set_instrs/1, get_instrs/0, get_stock_open_utc/0, get_shift_to_utc/0, speed_test/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-include("iqfeed_client.hrl").

-record(state, {
  dump_file :: file:io_device() | undefined,
  dump_current_size :: non_neg_integer(),
  dump_max_size :: non_neg_integer(),
  ip :: string(),
  port :: non_neg_integer(),
  instrs = [] :: [instr_name()], %% список акций, по которым запрашиваются тики
  watch_command :: iolist() | binary() | list(),
  sock = undefined :: undefined | gen_tcp:socket(),
  tick_fun :: tick_fun(),
  timezone :: string(),
  current_day :: calendar:date(),
  max_forward_time :: non_neg_integer(), %% maximum difference between current UTC time and tick time (when tick time is "in future"
  current_utc_forwarded_time :: non_neg_integer(), %% current UTC time shifted to max_forward_time (updated every T message from the Feed)
  stock_open_time :: calendar:time(),
  current_stock_open :: non_neg_integer(), %% UTC
  shift_to_utc :: integer(), %% current timezone shift to UTC
  ticks_enabled :: boolean(),
  enable_ticks_at_dayoffs :: boolean(),
  shift_to_dayoff_tz :: integer(), %% shift from IQFeed TZ to the TZ when filter out dayoffs (local)
  last_known_tick_time :: non_neg_integer() %% time of the last received tick (optimisation to reduce calculations of gregorian_seconds_to_datetime in ticks_enabled fun()
}).

-define(SERVER, ?MODULE).

-define(RECONNECT_TIMEOUT, 500).
-define(HANDSHAKE, <<"S,SET PROTOCOL,5.1", 10, 13>>).
-define(UPDATE_FIELDS, [
  <<"S,SELECT UPDATE FIELDS">>,
  <<",Most Recent Trade">>,             %% 2
  <<",Most Recent Trade Size">>,        %% 3
  <<",Most Recent Trade Date">>,        %% 4 	MM/DD/CCYY
  <<",Most Recent Trade TimeMS">>,      %% 5
  <<",Bid">>,                           %% 6
  <<",Ask">>,                           %% 7
  <<",Message Contents">>,              %% 8
  <<",Bid TimeMS">>, 10, 13]).            %% 9

-define(DUMP_FILE_MODE, [raw, binary, append, {delayed_write, 1024 * 4096, 1000}]).

-compile([{parse_transform, lager_transform}]).
%%%===================================================================
%%% API
%%%===================================================================

speed_test(ToSleep) ->
  TF = fun(_) -> ok end,
  Data = <<"Q,USDNOK.FXCM,7.76950,1,04/16/2018,04:37:23.479,7.76950,7.77095,Cba,04:37:23.479,">>,
  Timezone = "America/New_York",
  {Day, _} = localtime:utc_to_local(erlang:universaltime(), Timezone),
  StockOpenTime = {9, 30, 00},
  LocalSeconds = calendar:datetime_to_gregorian_seconds({Day, StockOpenTime}),
  UTCSeconds = calendar:datetime_to_gregorian_seconds(localtime:local_to_utc({Day, StockOpenTime}, Timezone)),
  MaxForwardTime = 10,
  Shift = UTCSeconds - LocalSeconds,
  Handle = undefined,
%%  case rz_util:get_env(iqfeed_client, tick_dump_enable) of
%%             true ->
%%               {ok, H} = file:open(rz_util:get_env(iqfeed_client, tick_dump), ?DUMP_FILE_MODE),
%%               H;
%%             false ->
%%               undefined
%%           end,
  EnableTicksAtDayoffs = false,
  State = #state{
    dump_file = Handle,
    dump_current_size = 0,
    dump_max_size = 10,
    watch_command = "w",
    tick_fun = TF,
    ip = undefined,
    port = undefined,
    instrs = [],
    timezone = Timezone,
    current_day = Day,
    max_forward_time = MaxForwardTime,
    current_utc_forwarded_time = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + MaxForwardTime,
    stock_open_time = StockOpenTime,
    current_stock_open = calendar:datetime_to_gregorian_seconds(localtime:local_to_utc({Day, StockOpenTime}, Timezone)),
    shift_to_utc = Shift,
    enable_ticks_at_dayoffs = EnableTicksAtDayoffs,
    ticks_enabled = true,
    shift_to_dayoff_tz = calendar:datetime_to_gregorian_seconds(erlang:localtime()) - calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
    last_known_tick_time = 0
  },
  Pid = spawn(fun() -> do_test(Data, State, 0) end),
  timer:sleep(ToSleep * 1000),
  Pid ! {get, self()},
  Done = receive
           {got, N} -> N
         end,
  io:format(" ~p reps; ~p Kreps/sec~n", [Done, Done / ToSleep / 1000]).

do_test(Data, State, N) ->
  {ok, NewState} = process_data(Data, State),
  receive
    {get, Recv} -> Recv ! {got, N}
  after 0 ->
    do_test(Data, NewState, N + 1)
  end.

%%--------------------------------------------------------------------
-spec(start_link(
    TickFun :: tick_fun(),
    IP :: string(),
    Port :: non_neg_integer(),
    Instrs :: [string() | binary()]) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(TickFun, IP, Port, Instrs) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [TickFun, IP, Port, Instrs], []).

%%--------------------------------------------------------------------
%% устанавливает новый список инструментов, старые инструменты удаляются
-spec set_instrs(Instrs :: [instr_name()]) -> {Added :: non_neg_integer(), Duplicates :: non_neg_integer()}.
set_instrs(Instrs) -> gen_server:call(?SERVER, {set_instrs, Instrs}, infinity).

%%--------------------------------------------------------------------
-spec get_instrs() -> [instr_name()].
get_instrs() -> gen_server:call(?SERVER, get_instrs, infinity).

%%--------------------------------------------------------------------
-spec get_stock_open_utc() -> non_neg_integer().
get_stock_open_utc() -> gen_server:call(?SERVER, get_stock_open_utc, infinity).

%%--------------------------------------------------------------------
-spec get_shift_to_utc() -> integer().
get_shift_to_utc() -> gen_server:call(?SERVER, get_shift_to_utc, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([TickFun, IP, Port, Instrs]) ->
  gen_server:cast(self(), connect),
  Timezone = rz_util:get_env(iqfeed_client, timezone),
  {Day, _} = localtime:utc_to_local(erlang:universaltime(), Timezone),
  StockOpenTime = rz_util:get_env(iqfeed_client, trading_start),
  LocalSeconds = calendar:datetime_to_gregorian_seconds({Day, StockOpenTime}),
  UTCSeconds = calendar:datetime_to_gregorian_seconds(localtime:local_to_utc({Day, StockOpenTime}, Timezone)),
  MaxForwardTime = rz_util:get_env(iqfeed_client, max_forward_time),
  Shift = UTCSeconds - LocalSeconds,
  Handle = case rz_util:get_env(iqfeed_client, tick_dump_enable) of
             true ->
               {ok, H} = file:open(rz_util:get_env(iqfeed_client, tick_dump), ?DUMP_FILE_MODE),
               H;
             false ->
               undefined
           end,
  EnableTicksAtDayoffs = rz_util:get_env(iqfeed_client, enable_ticks_at_dayoffs),
  State = #state{
    dump_file = Handle,
    dump_current_size = filelib:file_size(rz_util:get_env(iqfeed_client, tick_dump)),
    dump_max_size = rz_util:get_env(iqfeed_client, tick_dump_max_size),
    watch_command = rz_util:get_env(iqfeed_client, instr_watch_command),
    tick_fun = TickFun,
    ip = IP,
    port = Port,
    instrs = lists:usort(Instrs),
    timezone = Timezone,
    current_day = Day,
    max_forward_time = MaxForwardTime,
    current_utc_forwarded_time = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + MaxForwardTime,
    stock_open_time = StockOpenTime,
    current_stock_open = calendar:datetime_to_gregorian_seconds(localtime:local_to_utc({Day, StockOpenTime}, Timezone)),
    shift_to_utc = Shift,
    enable_ticks_at_dayoffs = EnableTicksAtDayoffs,
    ticks_enabled = true,
    shift_to_dayoff_tz = calendar:datetime_to_gregorian_seconds(erlang:localtime()) - calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
    last_known_tick_time = 0
  },
  {ok, ticks_enabled_locally(State)}.

%%--------------------------------------------------------------------
handle_cast(connect, State = #state{ip = IP, port = Port, sock = S}) when S =:= undefined ->
  SockOpts = [
    {active, once},
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
      gen_tcp:send(Sock, ?UPDATE_FIELDS),
      init_instrs(Sock, State#state.instrs, State#state.watch_command),
      {noreply, State#state{sock = Sock}};
    {error, Reason} ->
      lager:warning("IQFeed Level 1: couldn't connect due to: ~p", [Reason]),
      timer:sleep(?RECONNECT_TIMEOUT),
      gen_server:cast(self(), connect),
      {noreply, State}
  end.

%%--------------------------------------------------------------------
handle_info({tcp_error, S, Reason}, State) ->
  lager:warning("IQFeed Level 1 connection error: ~p", [Reason]),
  inet:setopts(S, [{active, once}]),
  {noreply, State};
%%---
handle_info({tcp_closed, _S}, State) ->
  lager:warning("IQFeed Level 1 connection closed"),
  gen_server:cast(self(), connect),
  {noreply, State#state{sock = undefined}};
%%---
handle_info({tcp, S, Data}, State) ->
  {ok, NewState} = process_data(Data, State),
  inet:setopts(S, [{active, once}]),
  {noreply, NewState}.

%%--------------------------------------------------------------------
handle_call({set_instrs, Instrs}, _From, State) ->
  UniqInstrs = lists:usort(Instrs),
  Total = erlang:length(Instrs),
  Added = erlang:length(UniqInstrs),
  lager:info("Loading additional instruments to IQFeed [~p]; unique:~p...", [Total, Added]),

  case State#state.sock of
    undefined -> ok;
    Sock -> init_instrs(Sock, UniqInstrs, State#state.watch_command)
  end,
  lager:info("Instruments are loaded."),
  {reply, {Added, Total - Added}, State#state{instrs = UniqInstrs}};
%%---
handle_call(get_instrs, _From, State) -> {reply, State#state.instrs, State};
%%---
handle_call(get_stock_open_utc, _From, State) -> {reply, State#state.current_stock_open, State};
%%---
handle_call(get_shift_to_utc, _From, State) -> {reply, State#state.shift_to_utc, State}.

%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_instrs(Socket, Instrs, WatchCommand) ->
  lists:foreach(fun(I) -> gen_tcp:send(Socket, [WatchCommand, I, 13, 10]) end, Instrs).

%%--------------------------------------------------------------------
-spec process_data(Data :: binary(), State :: #state{}) -> {ok, NewState :: #state{}}.
process_data(<<"Q,", _/binary>>, State = #state{ticks_enabled = false}) -> {ok, State};
process_data(AllData = <<"Q,", Data/binary>>, State) ->
  S = binary:split(Data, <<",">>, [global]),
  try
    [Name, Price, Vol, Date, Time,Bid, Ask, Opts | _] = S,
    Tick = #tick{
      name = Name,
      last_price = binary_to_float(Price),
      last_vol = binary_to_integer(Vol),
      time = bin2time(Date, Time, State),
      bid = binary_to_float(Bid),
      ask = binary_to_float(Ask)
    },
    UpdState = ticks_enabled(State, Tick#tick.time),
    case UpdState#state.ticks_enabled of
      true ->
        case Tick#tick.time of
          T when T > UpdState#state.current_utc_forwarded_time ->
            lager:warning("TICK-IN-FUTURE detected: ~p", [T]),
            {ok, UpdState};
          _ ->
            case Opts of
              <<"C", _/binary>> ->
                NewState = write_data([integer_to_binary(Tick#tick.time), <<"-">>, Data], UpdState),
                case Tick#tick.last_vol of
                  0 -> ok;
                  _ ->
                    (NewState#state.tick_fun)(Tick)
                end,
                {ok, NewState};
              _ ->
                {ok, UpdState}
            end
        end;
      false ->
        {ok, UpdState}
    end
  catch
    M:E ->
      lager:warning("Unexpected L1 update msg: ~p; error: ~p:~p", [AllData, M, E]),
      {ok, State}
  end;
%%---
process_data(<<"T,", Y:4/binary, M:2/binary, D:2/binary, " ", _/binary>>, State = #state{max_forward_time = MFT}) ->
  Day = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
  StockOpen = calendar:datetime_to_gregorian_seconds(
    localtime:local_to_utc({Day, State#state.stock_open_time}, State#state.timezone)),
  Shift = StockOpen - calendar:datetime_to_gregorian_seconds({Day, State#state.stock_open_time}),
  {
    ok,
    ticks_enabled_locally(
      State#state{
        current_day = Day,
        current_stock_open = StockOpen,
        shift_to_utc = Shift,
        current_utc_forwarded_time = calendar:datetime_to_gregorian_seconds(erlang:universaltime()) + MFT
        })
  };
%%---
process_data(Data, State) ->
  lager:debug("IQFeed Level 1 message: ~p", [Data]),
  {ok, State}.

%%--------------------------------------------------------------------
-spec bin2time(Date :: binary(), Time :: binary(), State :: #state{}) -> pos_integer().
bin2time(<<Mo:2/binary, $/, D:2/binary, $/, Y:4/binary>>, <<H:2/binary, $:, Mi:2/binary, $:, S:2/binary, _/binary>>, State) ->
  DateTime = {
    {binary_to_integer(Y), binary_to_integer(Mo), binary_to_integer(D)},
    {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)}
  },
  calendar:datetime_to_gregorian_seconds(DateTime) + State#state.shift_to_utc.

%%--------------------------------------------------------------------
-spec write_data(Data :: iolist(), State :: #state{}) -> #state{}.
write_data(_, State = #state{dump_file = undefined}) -> State;
write_data(Data, State) ->
  NewLength = State#state.dump_current_size + erlang:iolist_size(Data),
  if
    NewLength < State#state.dump_max_size ->
      file:write(State#state.dump_file, Data),
      State#state{dump_current_size = NewLength};
    true ->
      file:close(State#state.dump_file),
      FileName = rz_util:get_env(iqfeed_client, tick_dump),
      ok = file:rename(FileName, FileName ++ ".old"),
      {ok, H} = file:open(FileName, ?DUMP_FILE_MODE),
      file:write(H, Data),
      State#state{dump_current_size = erlang:iolist_size(Data), dump_file = H}
  end.

%%--------------------------------------------------------------------
-spec ticks_enabled(State :: #state{}, TickTime :: pos_integer()) -> #state{}.
ticks_enabled(#state{enable_ticks_at_dayoffs =  true}, _) -> true;
ticks_enabled(#state{last_known_tick_time = TickTime, enable_ticks_at_dayoffs = Enabled}, TickTime) -> Enabled;
ticks_enabled(State = #state{ticks_enabled = CurrentlyEnabled, shift_to_dayoff_tz = Shift}, TickTime) ->
  {D, _} = calendar:gregorian_seconds_to_datetime(TickTime + Shift),
  NewEnabled =
    case calendar:day_of_the_week(D) of
      6 -> false;
      7 -> false;
      _ -> true
    end,
  case NewEnabled of
    CurrentlyEnabled -> ok;
    _ -> lager:info("IQL1:: change dayoff tick filter to: ~p", [NewEnabled])
  end,
  State#state{ticks_enabled = NewEnabled, last_known_tick_time = TickTime}.

%%--------------------------------------------------------------------
-spec ticks_enabled_locally(State :: #state{}) -> #state{}.
ticks_enabled_locally(State) -> ticks_enabled(State, calendar:datetime_to_gregorian_seconds(erlang:localtime())).
