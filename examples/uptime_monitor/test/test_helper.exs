# Records enqueues made through a client set up by `use Zizq.Testing`,
# and backs `perform_job/3`.
{:ok, _} = Zizq.Testing.start_link()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(UptimeMonitor.Repo, :manual)
