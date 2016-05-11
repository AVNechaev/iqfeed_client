-ifndef(IQFEED_CLIENT_HRL).
-define(IQFEED_CLIENT_HRL, true).

-type(instr_name() :: binary()).

-record(tick, {
  name :: binary(),
  last_price :: float(),
  last_vol :: integer(),
  time :: pos_integer(),
  bid :: float(),
  ask :: float()
}).

-type(tick_fun() :: fun((Tick :: #tick{}) -> ok)).

-endif.