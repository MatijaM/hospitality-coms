defmodule HospitalityComsWeb.Presence do
  @moduledoc """
  Who is currently in a room, keyed on the engagement rather than the person.

  ## The key is an engagement id, and that is not a detail

  KTD2 says no employer-zone row may name a human and KTD15b says authorship
  resolves through the engagement, which is venue-local by construction. A
  presence entry is not a row, but it is a value that fans out to every other
  member of the room and across distributed Erlang, so the same rule applies:
  the key is `engagements.id`, which is exactly what a message already carries
  as `author_engagement_id`, and never `people.id`. A client that can render a
  message can render a presence entry with what it already has.

  The meta carries the employer-authored `role_label` off the same engagement
  and nothing else. There is no name here because there is no name in the
  employer zone to put here.

  ## What stops presence recovering a suspension (KTD18)

  U6 fixed a leak by *widening*: the venue room's roll is the venue's active
  engagements, unfiltered by suspension, so that subtracting two lists cannot
  recover who has opted out. Presence is a narrower set than the roll by
  construction — it is who has a socket open — and a suspended person is absent
  from it, so it could in principle be the arithmetic U6 closed, one connection
  at a time.

  Three things stop it, and none of them is a `select` list:

    * Presence is tracked only from channels on
      `HospitalityComsWeb.PersonSocket`. `EmployerSocket` routes no room topic
      at all (KTD9), so an employer session cannot join the channel that would
      deliver a `presence_diff`.
    * `HospitalityComs.PubSub.subscribe/2` refuses an employer scope handed a
      room topic by function clause, so an employer session cannot subscribe to
      the diffs without joining either.
    * No employer-facing function in the application reads presence. There is
      no employer-side venue-room membership function to hang one off — U6
      declined to write one for this reason.

  What remains is that any code running in this VM can call `list/1` on any
  topic, because presence is a process registry rather than a privilege. The
  boundary here is strong against accident and against a session; it is not a
  Postgres grant and does not claim to be.

  This used to cite `RESET ROLE` as the same residue, and since #17 that
  comparison is wrong in a way worth correcting rather than deleting.
  `EmployerRepo` now authenticates as a role that holds no privilege of its own,
  so the grant tier is *not* defeatable from this code position any more — where
  presence still is. The two are no longer the same kind of control, and this is
  the weaker one.

  ## Three things on the record, none of them closed here

  Written down so a later unit decides about them deliberately, in the place
  somebody extending presence will read.

  **A manager is also a worker, and can watch.** The three defences above are
  about the *employer* session. A manager holds a person scope at their own
  venue too — that is how they read the venue room at all — so they join the
  room's channel and receive its `presence_diff` stream like anybody else.
  Presence is a moment; watched over days it is a pattern, and somebody who is
  never once present while their colleagues come and go is distinguishable from
  somebody merely offline. That is KTD18's leak arriving through a door U6 did
  not close, because U6's fix was about two *lists* being the same set and this
  is about one list observed over time. Nothing here can fix it: presence is
  what it is for, and the alternative is not having it.

  **The meta is stamped at join and never refreshed.** `role_label` is copied
  off the engagement when the channel tracks itself. An employer renaming a role
  leaves every open channel advertising the old label until its next join, so
  two clients in one room can disagree about what somebody is called. Harmless
  today because nothing authorises on a label; it stops being harmless the first
  time something does.

  **A netsplit keeps a revoked worker visible for about twenty minutes.**
  `Phoenix.Tracker`'s `:permdown_period` defaults to 1_200_000 ms, and until it
  elapses a partitioned replica's presences stay listed on the surviving nodes.
  `HospitalityComs.Application` starts `DNSCluster`, so more than one node is
  intended rather than hypothetical. This costs nothing in *authority* — the
  revoked person's own channel is on the far side of the split and their rejoin
  is refused wherever it lands — but the room shows them as present for as long
  as the period runs, which is the one place presence and membership can visibly
  disagree.

  ## `fetch/2` is left as the identity, deliberately

  The framework invokes `fetch/2` from a process of its own, which is why its
  own testing note is about draining fetchers before a test's connections are
  checked in. Ours cannot outlive anything interesting, because it does no work:
  everything a client needs was resolved by the join that tracked the entry.
  `HospitalityComsWeb.PresenceTest` asserts the drain regardless — "it cannot
  happen" is the kind of sentence that stops being true when somebody adds a
  preload.

  The functions `use Phoenix.Presence` generates (`track/3`, `list/1`,
  `fetchers_pids/0`, …) are the framework's and carry no `@spec`; the ones this
  module writes do.
  """

  use Phoenix.Presence,
    otp_app: :hospitality_coms,
    pubsub_server: HospitalityComs.PubSub

  alias HospitalityComs.Engagements.Engagement
  alias Phoenix.Socket

  @doc """
  Tracks the joining channel under its engagement.

  Called from `handle_info(:after_join, socket)` rather than from `join/3`,
  because a channel cannot track itself before it has finished joining — the
  tracker would be registering a process that is not yet subscribed to its own
  topic.

  `:not_tracked` is every way `Phoenix.Tracker` can decline, collapsed. The
  library's reason is unbounded — `{:error, {:already_tracked, pid, topic,
  key}}` is the documented one and nothing promises it is the last — and
  `AGENTS.md` names `{:error, term()}` as the thing not to write. It is
  collapsed in the body rather than only in the spec, the way
  `HospitalityComs.Accounts.PersonNotifier` collapses `Mailer.deliver!/1`'s
  reason into `:delivery_failed`, so the promise is kept by the code and not
  only by the annotation.
  """
  @spec track_engagement(Socket.t(), Engagement.t(), DateTime.t()) ::
          {:ok, binary()} | {:error, :not_tracked}
  def track_engagement(%Socket{} = socket, %Engagement{} = engagement, %DateTime{} = joined_at) do
    socket
    |> track(engagement.id, %{
      role_label: engagement.role_label,
      joined_at: DateTime.to_iso8601(joined_at)
    })
    |> tracked()
  end

  @spec tracked({:ok, binary()} | {:error, term()}) :: {:ok, binary()} | {:error, :not_tracked}
  defp tracked({:ok, ref}) when is_binary(ref), do: {:ok, ref}
  defp tracked({:error, _reason}), do: {:error, :not_tracked}
end
