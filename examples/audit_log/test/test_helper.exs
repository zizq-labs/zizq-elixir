# Records enqueues made through a client set up by `use Zizq.Testing`.
# The audit log is a consumer and enqueues nothing itself, but the
# recorder also backs `perform_job/3`, which is how the job handlers
# are exercised.
{:ok, _} = Zizq.Testing.start_link()

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(AuditLog.Repo, :manual)
