-type(instr_name() :: string() | binary()).

-record(tick, {
  name :: binary(),
  last_price :: float(),
  last_vol :: integer(),
  time :: calendar:time(),
  bid :: float(),
  ask :: float()
}).

-type(tick_fun() :: fun((Tick :: #tick{}) -> ok)).