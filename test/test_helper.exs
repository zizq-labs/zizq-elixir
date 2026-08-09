# The default 100ms is tight for assertions that wait on a real HTTP
# round trip to the in-process fake server, especially on slower or
# loaded machines. Only affects positive assertions; `refute_receive`
# keeps its own (short) default, which is what you want for proving
# something did *not* happen.
ExUnit.configure(assert_receive_timeout: 2_000)

ExUnit.start()
