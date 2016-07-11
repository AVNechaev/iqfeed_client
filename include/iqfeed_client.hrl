-ifndef(IQFEED_CLIENT_HRL).
-define(IQFEED_CLIENT_HRL, true).

-include_lib("rz_util/include/rz_util.hrl").

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