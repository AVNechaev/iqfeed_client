%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Feb 2016 22:06
%%%-------------------------------------------------------------------
-module(iq_test).
-author("anechaev").

-include("iqfeed_client.hrl").
%% API
-export([run/0]).
-compile([{parse_transform, lager_transform}]).
run() ->
  F = fun(Tick) -> lager:info("TICK: ~p", [Tick]) end,
  application:set_env(lager, handlers, [{lager_console_backend, info}]),
  lager:start(),
  application:set_env(iqfeed_client, iqfeed_ip, "127.0.0.1"),
  application:set_env(iqfeed_client, iqfeed_l1_port, 5009),
  iq_sup:start_link(F),
  iq_ifc:update_instrs("/home/anechaev/tmp/iqinstr.csv"),
  ok.