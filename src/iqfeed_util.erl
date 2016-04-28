%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Feb 2016 21:20
%%%-------------------------------------------------------------------
-module(iqfeed_util).
-author("anechaev").

-include("iqfeed_client.hrl").
%% API
-export([load_instr_csv/1, load_instr_csv/3, get_env/2]).

-compile([{parse_transform, lager_transform}]).

%%--------------------------------------------------------------------
-spec load_instr_csv(FileName :: string()) -> {ok, Instrs :: [instr_name()]} | {error, Reason :: any()}.
load_instr_csv(FileName) -> load_instr_csv(FileName, 1, []).

%% возвращает список инструментов с удаленными дубликатами
-spec load_instr_csv(FileName :: string(), SkipHeaderLines :: non_neg_integer(), Defaults :: [instr_name()]) -> {ok, Instrs :: [instr_name()]} | {error, Reason :: any()}.
load_instr_csv(FileName, SkipHeaderLines, Defaults) ->
  try
    {ok, H} = file:open(FileName, [raw, binary, read]),
    [{ok, _} = file:read_line(H) || _ <- lists:seq(1, SkipHeaderLines)],
    {ok, lists:usort(int_read_csv(H) ++ Defaults)}
  catch
    M:E ->
      lager:warning("Error reading ~p: (~p:~p); ~p", [FileName, M, E, erlang:get_stacktrace()]),
      {error, {M, E}}
  end.

%%--------------------------------------------------------------------
-spec get_env(App :: atom(), Par :: atom()) -> any().
get_env(App, Par) ->
  {ok, V} = application:get_env(App, Par),
  V.

%%%===================================================================
%%% Internal functions
%%%===================================================================
int_read_csv(H) -> int_read_csv(H, []).
int_read_csv(H, Acc) ->
  case file:read_line(H) of
    eof ->
      Acc;
    {ok, <<>>} ->
      int_read_csv(H, Acc);
    {ok, <<10>>} ->
      int_read_csv(H, Acc);
    {ok, Bin} ->
      [_F1, _F2, Instr, _F4, _F5, _F6, _F7, _F8, _F9, _F10, _F11] = binary:split(Bin, <<",">>, [global]),
      int_read_csv(H, [Instr | Acc])
  end.