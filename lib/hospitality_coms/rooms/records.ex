defmodule HospitalityComs.Rooms.Records do
  @moduledoc """
  Every query the two room kinds ask, in one module.

  `HospitalityComs.Rooms` and `HospitalityComs.Rosters` are the public APIs and
  this is where their `where` clauses live, for the reason `AGENTS.md` gives and
  the reason `HospitalityComs.Engagements.Records` gives more sharply: two of
  these clauses *are* the authorization model. "In this room" and "may read this
  room" are not filters on an answer, they are the answer.

  ## Nothing here reads a clock, and nothing here is stored

  Every function takes the instant. It is captured once at the unit-of-work
  boundary and carried on the scope (KTD5); a query module that reached for
  `Clock.now/0` would let two queries in one request disagree about which side
  of a boundary the work fell on. `Ecto.Query.ago/2` and `from_now/2` are banned
  project-wide and a Credo check enforces it.

  Nothing below is a lookup of a materialised set. There is no membership table,
  no snapshot, and **no job**: the same call at a later instant returns a
  different set because the instant moved. KTD6b is why, and the argument is
  worth restating because the alternative is the obvious design — a job that
  materialises a shift room's membership at shift start inverts under its own
  failure mode, because firing ten minutes late captures the roster *as
  corrected*, which is the retroactive withdrawal it existed to prevent, and its
  absence is indistinguishable from an empty roster.

  ## Half-open, four times, and they have to agree

  Four intervals matter here and every one of them is `[lower, upper)` (KTD4):

  | Interval | Lower | Upper |
  |---|---|---|
  | engagement | `starts_at` | `ends_at` |
  | shift room's open window | `starts_at` | `closes_at` |
  | roster entry | `joined_at` | `left_at`, null meaning unbounded |
  | venue-room suspension | `suspended_at` | `resumed_at`, null meaning unbounded |

  **Containment** of an instant is `lower <= t and upper > t`.
  `HospitalityComs.Engagements.Records.active_at/2` is that predicate for the
  first row; `open_at/2`, `rostered_at/2` and `suspended_at/2` below are the same
  predicate for the other three, differing only in the column names and in the
  nulls two of them permit. Where an engagement is involved these queries reuse
  `active_at/2` itself through a subquery rather than respelling it — see
  `active_engagement_ids/2` — so the predicate that decides activeness is
  literally the same one U5 shipped.

  **Overlap** of two of them is `overlapping_open_interval/1`, and it is the one
  piece of logic in this unit that is not a restatement of something U5 already
  proved:

      both non-empty, and lower_a < upper_b, and lower_b < upper_a

  The emptiness clause is not decoration. A roster entry added and removed at
  the same instant is `[a, a)`, which contains no instant and must therefore
  overlap nothing — and the endpoint form without that clause reports an overlap
  for it, because `a < upper_b` and `lower_b < a` can both hold. Postgres's `&&`
  on the generated `tstzrange` columns gets this right for free; the Ecto
  spelling has to say it. `HospitalityComs.RoomsTest` asserts the two agree over
  a matrix of interval pairs rather than taking this paragraph's word for it.

  Containment is a special case of overlap — `period @> t` is
  `period && [t, t]` — which is why one convention has to hold across all of
  them.

  ## Named bindings, so a predicate is written once

  The roster queries all start from `roster/0`, which joins a roster entry to
  its shift room and names both bindings. That is what lets
  `overlapping_open_interval/1` and `open_at/2` be *one* function each rather
  than one per call site: the same clause composes onto a query about one room's
  members, one room's readers, and the rooms one person may read.

  ## Which side each query is asked from

  Shift-room membership and readability are `roster_entries` joined to
  `engagements` — both employer-zone reads — so they answer under an employer
  scope through `HospitalityComs.EmployerRepo` and under a person scope through
  `HospitalityComs.Repo` alike.

  Anything reaching `unsuspended/2` is not. It subtracts
  `venue_room_suspensions`, which is a **person-zone** table (KTD18), so an
  employer-scoped query composing it raises
  `HospitalityComs.EmployerRepo.ZoneViolationError` before Postgres is asked,
  and Postgres would refuse it for want of privilege if the backstop were
  removed. Two queries reach it and both are about one named person:
  `venue_room_membership/3` and `venues_of_person/2`.

  `venue_room_members/2` deliberately does **not**, and its docstring is where
  that argument is written down. A roll that subtracted suspensions would differ
  from `HospitalityComs.Engagements.list_engagements/1` by exactly the set of
  people who had opted out — and a manager holds both scopes, so the difference
  is one subtraction away from anybody the guarantee is aimed at. The grant tier
  keeps the *rows* out of employer reach; keeping the two lists identical is
  what keeps the fact out of reach.
  """

  import Ecto.Query

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Records, as: EngagementRecords
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues.Venue

  ## Shift rooms

  @doc """
  Every shift room, with its binding named so the predicates below compose.
  """
  @spec rooms() :: Ecto.Query.t()
  def rooms, do: from(room in ShiftRoom, as: :room)

  @doc """
  Shift rooms at one venue.
  """
  @spec of_venue(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def of_venue(queryable, venue_id) when is_binary(venue_id) do
    from [room: room] in queryable, where: room.venue_id == ^venue_id
  end

  @doc """
  One shift room, by id.
  """
  @spec room(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def room(queryable, room_id) when is_binary(room_id) do
    from [room: room] in queryable, where: room.id == ^room_id
  end

  @doc """
  Shift rooms at a venue where this person holds an engagement active at
  `instant`.

  The refusal boundary for every person-scoped read of a room by id. Without it
  the three answers a send can give — no such room, the room is shut, you are
  not on its roster — enumerate the shift rooms of every venue in the database
  one id at a time, which is the not-found-rather-than-forbidden rule (AE1) lost
  at the one place a caller supplies the id.

  Inside it the answers are safe: a person engaged at a venue may know that
  venue runs shifts. Outside it every id is `:not_found`.

  It deliberately does **not** subtract suspensions. Suspension is the venue
  room only (KTD18), and a suspended person is still on their shift rosters.
  """
  @spec at_person_venues(Ecto.Queryable.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def at_person_venues(queryable, person_id, %DateTime{} = instant) when is_binary(person_id) do
    venue_ids =
      Engagement
      |> EngagementRecords.of_person(person_id)
      |> EngagementRecords.active_at(instant)
      |> select([engagement], engagement.venue_id)

    from [room: room] in queryable, where: room.venue_id in subquery(venue_ids)
  end

  @doc """
  Shift rooms whose open window contains `instant`.

  `starts_at <= instant < closes_at`, where `closes_at` is the generated column
  `ends_at + grace`. Half-open, so a room with a grace of zero stops accepting
  messages at exactly `ends_at` and a room with thirty minutes' grace stops at
  exactly `ends_at + 30m` — the instant a room closes belongs to the closed
  side.

  This is a **write** window. R11 keeps the room readable afterwards to everyone
  whose roster period overlapped it, which is `overlapping_open_interval/1` and
  has no clock of its own.
  """
  @spec open_at(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def open_at(queryable, %DateTime{} = instant) do
    from [room: room] in queryable,
      where: room.starts_at <= ^instant,
      where: room.closes_at > ^instant
  end

  @doc """
  Earliest shift first, with `id` breaking ties.

  Ordering by `id` alone is random on a `binary_id` schema, so "earliest first"
  would be a sentence the query did not implement.
  """
  @spec earliest_first(Ecto.Queryable.t()) :: Ecto.Query.t()
  def earliest_first(queryable) do
    from [room: room] in queryable, order_by: [asc: room.starts_at, asc: room.id]
  end

  @doc """
  The rooms a query reaches, once each.

  `DISTINCT` is needed because one person can hold several roster periods on one
  shift — rostered, removed, rostered again — and each of them overlaps. Every
  column `earliest_first/1` orders on is in this select list, which is what
  Postgres requires of a `SELECT DISTINCT`.
  """
  @spec distinct_rooms(Ecto.Queryable.t()) :: Ecto.Query.t()
  def distinct_rooms(queryable) do
    from [room: room] in queryable, distinct: true, select: room
  end

  ## Roster entries

  @doc """
  Every roster entry joined to the shift room it is on.

  The base every roster query composes from. The join is what lets the overlap
  and openness predicates be written once and applied to questions asked from
  either end — one room's roster, or one person's rooms.
  """
  @spec roster() :: Ecto.Query.t()
  def roster do
    from entry in RosterEntry,
      as: :entry,
      join: room in ShiftRoom,
      on: room.id == entry.shift_room_id and room.venue_id == entry.venue_id,
      as: :room
  end

  @doc """
  Roster entries on one shift room.
  """
  @spec of_room(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def of_room(queryable, room_id) when is_binary(room_id) do
    from [entry: entry] in queryable, where: entry.shift_room_id == ^room_id
  end

  @doc """
  Roster entries held by one engagement.
  """
  @spec of_engagement(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def of_engagement(queryable, engagement_id) when is_binary(engagement_id) do
    from [entry: entry] in queryable, where: entry.engagement_id == ^engagement_id
  end

  @doc """
  Roster entries at one venue.

  Redundant next to the row-level security policy on the same column, and kept
  for the reason every other explicit venue filter in this application is kept:
  the filter is what makes the query mean what it says, and the policy is what
  makes a mistake safe.
  """
  @spec entries_of_venue(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def entries_of_venue(queryable, venue_id) when is_binary(venue_id) do
    from [entry: entry] in queryable, where: entry.venue_id == ^venue_id
  end

  @doc """
  Roster entries nobody has closed.

  Not the same set as `rostered_at/2`: an entry rostered for tomorrow is open
  and contains no instant today. `HospitalityComs.Rosters.remove_from_roster/3`
  wants this one, because an entry whose period has not begun is exactly the one
  a mistaken rostering has to be undoable through.
  """
  @spec still_open(Ecto.Queryable.t()) :: Ecto.Query.t()
  def still_open(queryable) do
    from [entry: entry] in queryable, where: is_nil(entry.left_at)
  end

  @doc """
  Roster entries whose period contains `instant`.

  `joined_at <= instant and (left_at is null or left_at > instant)` — the same
  half-open containment `HospitalityComs.Engagements.Records.active_at/2`
  spells, with a null upper bound meaning "still rostered" rather than a missing
  value.

  An entry removed at the instant it was added is `[a, a)` and is contained by
  nothing: `a <= a` holds and `a > a` does not.
  """
  @spec rostered_at(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def rostered_at(queryable, %DateTime{} = instant) do
    from [entry: entry] in queryable,
      where: entry.joined_at <= ^instant,
      where: is_nil(entry.left_at) or entry.left_at > ^instant
  end

  @doc """
  Roster entries whose period **overlaps** their room's open window.

  The read scope R10 and R11 define, and the highest-risk predicate in this
  unit. Two half-open intervals overlap iff both are non-empty and each starts
  before the other ends:

    * `entry.joined_at < room.closes_at` — the entry starts before the room
      shuts. A null `left_at` needs nothing further: an unbounded entry ends
      after everything.
    * `entry.left_at > room.starts_at` — the entry ends after the room opens.
      This is what makes "rostered on Monday for Friday, removed on Tuesday" not
      a member: the period closed before the room ever opened.
    * `entry.left_at > entry.joined_at` — the entry is non-empty. Without it,
      an entry added and removed at the same instant *inside* the room's window
      would satisfy the two clauses above and be reported as overlapping,
      because it starts before the room shuts and ends after the room opens.
      An empty interval overlaps nothing, and Postgres's `&&` on the generated
      ranges agrees; this clause is what makes the Ecto spelling agree too.

  The room's own window is never empty — `ends_at > starts_at` is a check
  constraint and the grace is non-negative — so there is no fourth clause.

  Nothing here mentions an instant. That is the point: once a roster period has
  overlapped a room's open window, no later write can unmake it. Removal only
  ever moves the upper bound forward from the instant of the removal, so the
  part of the period that already elapsed is untouchable. Non-retroactivity is
  structural rather than defended (KTD6b).
  """
  @spec overlapping_open_interval(Ecto.Queryable.t()) :: Ecto.Query.t()
  def overlapping_open_interval(queryable) do
    from [entry: entry, room: room] in queryable,
      where: entry.joined_at < room.closes_at,
      where:
        is_nil(entry.left_at) or
          (entry.left_at > entry.joined_at and entry.left_at > room.starts_at)
  end

  @doc """
  The engagements a roster query names.
  """
  @spec engagement_ids(Ecto.Queryable.t()) :: Ecto.Query.t()
  def engagement_ids(queryable) do
    from [entry: entry] in queryable, select: entry.engagement_id
  end

  @doc """
  The entries themselves, earliest joined first.
  """
  @spec entries(Ecto.Queryable.t()) :: Ecto.Query.t()
  def entries(queryable) do
    from [entry: entry] in queryable,
      order_by: [asc: entry.joined_at, asc: entry.id],
      select: entry
  end

  ## Engagements, reached through U5's own predicates

  @doc """
  The ids of the engagements a query names that are active at `instant`.

  A projection of `HospitalityComs.Engagements.Records.active_at/2` rather than
  a second spelling of it, so that "active" cannot come to mean two things. It
  is the same manoeuvre `Engagements.Records.live_grant_ids/2` makes for grants,
  and for the same reason.
  """
  @spec active_engagement_ids(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def active_engagement_ids(queryable, %DateTime{} = instant) do
    queryable
    |> EngagementRecords.active_at(instant)
    |> select([engagement], engagement.id)
  end

  @doc """
  Engagements that carry no suspension containing `instant`.

  **Person zone.** `venue_room_suspensions` is classified `:person`, so an
  employer-scoped query composing this raises
  `HospitalityComs.EmployerRepo.ZoneViolationError` naming the table, and
  Postgres would refuse it for want of privilege if the backstop were removed.
  That is KTD18 being a property of the grant tier rather than of a `select`
  list somebody remembers to trim.

  `not in subquery` is safe against the three-valued trap that usually makes
  `NOT IN` wrong: `venue_room_suspensions.engagement_id` is `NOT NULL`, so the
  subquery cannot yield a null and cannot turn the predicate into `UNKNOWN` for
  every row.
  """
  @spec unsuspended(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def unsuspended(queryable, %DateTime{} = instant) do
    from engagement in queryable,
      where: engagement.id not in subquery(suspended_engagement_ids(instant))
  end

  @doc """
  The venue room's roll at `instant`: the venue's active engagements.

  R9 in one query, and nothing stores it. Advancing the clock past an
  engagement's upper bound removes that person with no job having run.

  **It does not subtract suspensions, and that is KTD18 rather than an
  omission.** This set is exactly what `HospitalityComs.Engagements
  .list_engagements/1` already returns to an employer session, and it has to
  stay exactly that. A manager is a worker too — they hold an engagement like
  anybody else — so one caller can hold an employer scope and a person scope at
  the same venue and read both lists in the same breath. Subtract suspensions
  here and the difference between the two lists *is* the set of people who have
  opted out, recovered by arithmetic from inside the room, with the grant tier
  and the query backstop both intact and both bypassed.

  Suspension is therefore not a departure from the room. It closes the
  suspended person's own access and nothing else: `venue_room_membership/3`
  keeps `unsuspended/2`, so they cannot read the room, cannot send to it, and do
  not see it in their own list of rooms. Nobody else's answer changes, which is
  what makes the opt-out unobservable rather than merely unlogged.

  Nothing is lost by the roll being wider than the set that can read the room
  *right now*: the venue room carries full history (R14, KTD14), so a suspended
  person reads everything said while they were away the moment they resume. The
  roll was never a list of who is looking.

  **Returns whole `HospitalityComs.Engagements.Engagement` structs, and one of
  their fields is `person_id`.** U8/U9 render this to every member of the room;
  they should project a field list rather than the struct, and attribute on
  `id` — the `author_engagement_id` a message already carries (KTD15b), which is
  venue-local by construction — rather than on `person_id`. The same note sits
  on `HospitalityComs.Engagements.Records.outstanding_invitations/2` for the
  same reason.
  """
  @spec venue_room_members(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def venue_room_members(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    Engagement
    |> EngagementRecords.of_venue(venue_id)
    |> EngagementRecords.active_at(instant)
    |> EngagementRecords.oldest_first()
  end

  @doc """
  One person's engagement at one venue, active at `instant`, suspended or not.

  What `HospitalityComs.Rooms.suspend_venue_room/2` and `resume_venue_room/2`
  resolve: a suspended person is still engaged, so the read that finds the
  engagement to resume must not be the read that excludes them from the room.
  """
  @spec venue_engagement(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def venue_engagement(person_id, venue_id, %DateTime{} = instant)
      when is_binary(person_id) and is_binary(venue_id) do
    Engagement
    |> EngagementRecords.of_person(person_id)
    |> EngagementRecords.of_venue(venue_id)
    |> EngagementRecords.active_at(instant)
  end

  @doc """
  One person's membership of one venue room at `instant`.

  `venue_engagement/3` intersected with not being suspended, which is the
  difference between "engaged here" and "in the room".
  """
  @spec venue_room_membership(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def venue_room_membership(person_id, venue_id, %DateTime{} = instant) do
    person_id |> venue_engagement(venue_id, instant) |> unsuspended(instant)
  end

  @doc """
  The venues whose rooms this person is in at `instant`, by name.

  Ordered by name with `id` breaking ties, because a venue's name is what a
  client renders and `id` is random on a `binary_id` schema.
  """
  @spec venues_of_person(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def venues_of_person(person_id, %DateTime{} = instant) when is_binary(person_id) do
    member_venue_ids =
      Engagement
      |> EngagementRecords.of_person(person_id)
      |> EngagementRecords.active_at(instant)
      |> unsuspended(instant)
      |> select([engagement], engagement.venue_id)

    from venue in Venue,
      where: venue.id in subquery(member_venue_ids),
      order_by: [asc: venue.name, asc: venue.id]
  end

  @doc """
  One venue that is still trading, taken under `FOR SHARE`.

  What every venue-room *write* resolves before it writes. A venue-room message
  has no deletion clock until `HospitalityComs.Lifecycle.close_venue/2` stamps
  one, and closure stamps only the rows that exist when it runs — so a message
  written after it carries a null deadline nothing can ever match, and
  `close_venue/2` refuses to run a second time.

  The lock mode is the whole of the race half. `FOR SHARE` conflicts with the
  `FOR NO KEY UPDATE` the closure's `UPDATE venues` takes, so a send whose
  snapshot predates the closure parks and then re-evaluates `closed_at IS NULL`
  against the committed row rather than inserting behind the stamping statement.
  Several sends may hold it at once, which is why it is `FOR SHARE` and not
  `FOR UPDATE`: two people talking in a venue room must not serialise on the
  venue.
  """
  @spec trading_venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def trading_venue(venue_id) when is_binary(venue_id) do
    from venue in Venue,
      where: venue.id == ^venue_id,
      where: is_nil(venue.closed_at),
      lock: "FOR SHARE"
  end

  ## Shift rooms, from both ends

  @doc """
  The engagements in a shift room at `instant`.

  Rostered at `instant`, in a room that is open at `instant`, holding an
  engagement active at `instant`. All three are containment, and all three move
  on their own without a write.

  Suspension is deliberately absent: KTD18 confines it to the venue room, and
  this query could not consult it in any case without becoming a person-zone
  read that no employer scope may run.
  """
  @spec shift_room_members(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def shift_room_members(room_id, %DateTime{} = instant) when is_binary(room_id) do
    rostered =
      roster()
      |> of_room(room_id)
      |> rostered_at(instant)
      |> open_at(instant)
      |> engagement_ids()

    Engagement
    |> where([engagement], engagement.id in subquery(rostered))
    |> EngagementRecords.active_at(instant)
    |> EngagementRecords.oldest_first()
  end

  @doc """
  The engagements that may read a shift room at `instant`.

  The overlap set intersected with an active engagement, which is KTD14's
  snapshot scope without a snapshot and the resolution of the origin document's
  R14/R16 contradiction. It is wider than `shift_room_members/2` in one
  direction — somebody removed from the roster an hour ago is still here — and
  narrower in another: an engagement that has since ended is not.
  """
  @spec shift_room_readers(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def shift_room_readers(room_id, %DateTime{} = instant) when is_binary(room_id) do
    overlapped =
      roster()
      |> of_room(room_id)
      |> overlapping_open_interval()
      |> engagement_ids()

    Engagement
    |> where([engagement], engagement.id in subquery(overlapped))
    |> EngagementRecords.active_at(instant)
    |> EngagementRecords.oldest_first()
  end

  @doc """
  The shift rooms this person may read at `instant`, earliest first.

  The same overlap, asked from the other end. A person engaged today sees no
  room from before their engagement, because they were on nobody's roster then
  — which is KTD14 refusing the day-one hire the venue's whole shift history.
  """
  @spec readable_shift_rooms(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def readable_shift_rooms(person_id, %DateTime{} = instant) when is_binary(person_id) do
    active =
      Engagement
      |> EngagementRecords.of_person(person_id)
      |> active_engagement_ids(instant)

    roster()
    |> overlapping_open_interval()
    |> where([entry: entry], entry.engagement_id in subquery(active))
    |> distinct_rooms()
    |> earliest_first()
  end

  ## Messages

  @doc """
  A venue room's messages, oldest first.

  `shift_room_id IS NULL` is what makes a message the venue room's. There is no
  time filter and there will not be one: KTD14 gives the venue room full history
  (R14), so a person engaged today reads what was said before they arrived.

  **The `venue_id` filter is the only thing holding this read to one venue.**
  `room_messages` carries a row-level security policy that binds nobody —
  `employer_role` holds no privilege on the table and the only accessor,
  `HospitalityComs.Repo`, owns it and is not bound by a policy that is not
  `FORCE`d, which it cannot be. `*_enable_room_row_level_security.exs` sets out
  why. What the caller cannot do is choose the venue: it comes off the
  engagement `HospitalityComs.Rooms.fetch_membership/2` resolved for this person
  at this instant.
  """
  @spec venue_room_messages(Ecto.UUID.t()) :: Ecto.Query.t()
  def venue_room_messages(venue_id) when is_binary(venue_id) do
    from message in RoomMessage,
      where: message.venue_id == ^venue_id,
      where: is_nil(message.shift_room_id),
      order_by: [asc: message.sent_at, asc: message.id]
  end

  @doc """
  A shift room's messages, oldest first.

  Unfiltered by instant for the same reason: the room stops accepting messages
  at `closes_at` and stops being readable never. Who may run this is
  `shift_room_readers/2`.

  Unfiltered by venue too, and that one is a database guarantee rather than an
  omission: `room_messages_shift_room_fkey` is a composite key into
  `shift_rooms (id, venue_id)`, so every row naming a room carries that room's
  venue and no other's. `HospitalityComs.RoomsTest` asserts it by writing the
  row Postgres has to refuse.
  """
  @spec shift_room_messages(Ecto.UUID.t()) :: Ecto.Query.t()
  def shift_room_messages(room_id) when is_binary(room_id) do
    from message in RoomMessage,
      where: message.shift_room_id == ^room_id,
      order_by: [asc: message.sent_at, asc: message.id]
  end

  ## Suspensions

  @doc """
  Suspensions whose period contains `instant`.

  `suspended_at <= instant and (resumed_at is null or resumed_at > instant)` —
  the same half-open containment as everything else, with a null upper bound
  meaning "still out".
  """
  @spec suspended_at(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def suspended_at(queryable, %DateTime{} = instant) do
    from suspension in queryable,
      where: suspension.suspended_at <= ^instant,
      where: is_nil(suspension.resumed_at) or suspension.resumed_at > ^instant
  end

  @doc """
  The engagements suspended at `instant`.
  """
  @spec suspended_engagement_ids(DateTime.t()) :: Ecto.Query.t()
  def suspended_engagement_ids(%DateTime{} = instant) do
    VenueRoomSuspension
    |> suspended_at(instant)
    |> select([suspension], suspension.engagement_id)
  end

  @doc """
  One engagement's suspension, if it is in force at `instant`.

  What `HospitalityComs.Rooms.resume_venue_room/2` closes, and what makes
  suspending twice `{:error, :already_suspended}` rather than a second open row.
  """
  @spec open_suspension(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def open_suspension(engagement_id, %DateTime{} = instant) when is_binary(engagement_id) do
    VenueRoomSuspension
    |> where([suspension], suspension.engagement_id == ^engagement_id)
    |> suspended_at(instant)
  end
end
