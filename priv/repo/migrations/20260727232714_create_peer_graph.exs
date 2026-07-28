defmodule HospitalityComs.Repo.Migrations.CreatePeerGraph do
  @moduledoc """
  The three tables the peer graph is, and the two it deliberately is not.

  ## Everything here names a person, so everything here is person zone

  KTD2 permits exactly one crossing — `engagements.person_id` — and it permits
  it in one direction: an employer-zone row may never name a human. A peer
  connection is between *people* and nothing else; there is no venue in it, no
  engagement, and no role. So these tables carry no `venue_id`, hold no key into
  the employer zone, and are classified `:person` in `HospitalityComs.Zones`.

  `HospitalityComs.BoundaryTest` asserts the consequence in its positive form:
  `engagements` is the only table *outside* the person zone with a foreign key
  to `people`. Classifying any of these three anywhere else fails that
  assertion, which is why the classification is not a judgement call.

  A person-zone table also earns no row-level security policy here, for the
  reason `venue_room_suspensions` earns none: `employer_role` holds no privilege
  at all, and the only accessor is `HospitalityComs.Repo`, which owns the tables
  and is therefore not bound by a policy that is not `FORCE`d — and `FORCE` is
  not available, because the predicate would have to read `app.employer_id`,
  which is unset on every person-side read there is.

  ## What is *not* here: a visibility table

  Visibility between two people is a derived interval per pair per venue —
  `[max(their two starts), min(their two ends) + 30 days)` — and storing it
  would be the cached authorization decision the whole design exists to prevent.
  It would also be wrong almost immediately: `engagements.ends_at` moves under
  renewal and under ending, so a materialised tail is stale from the first
  renewal, and a job that refreshed it would inherit KTD6b's entire failure
  class. `HospitalityComs.Peers.Records` asks the question instead, and advancing
  the clock lapses visibility with nothing having run.

  There is no `conversations` table either. A conversation *is* a live
  connection, seen from one side; giving it a row would create a second place
  for it to be, which is the mistake `HospitalityComs.Rooms.VenueRoom` declines
  at venue-room scale.

  ## The pair is an unordered thing, so it is stored as an ordered one

  A unique index cannot express "at most one row for the pair {A, B}" while the
  pair is spelled two different ways depending on who asked first. Both tables
  therefore carry a canonical form.

  `connection_requests` generates it: `pair_low_id` and `pair_high_id` are
  `GENERATED ALWAYS AS LEAST/GREATEST(requester_id, addressee_id) STORED`, so no
  writer can get it wrong and no changeset has to remember it. `LEAST` over
  `uuid` was checked against Postgres before this relied on it — it is immutable
  enough for a generated column, which not every function is.

  `peer_connections` cannot generate it, because the two columns *are* the
  identity of the row rather than a projection of one, so it takes the check
  constraint `person_a_id < person_b_id` instead and
  `HospitalityComs.Peers.Connection` orders the pair on the way in.

  ## One current request per pair, and it is the whole state machine

  `superseded_at` is what makes "the pair's current row" a database guarantee
  rather than an ordering convention. A partial unique index on
  `(pair_low_id, pair_high_id) WHERE superseded_at IS NULL` means exactly one row
  per pair is current, and creating a new request supersedes the previous one in
  the same transaction.

  The alternative — read the pair's most recent row by `(requested_at, id)` — is
  not safe here, and the reason is specific to this application rather than
  general. The clock is injectable and tests pin it, so a decline and the
  counterpart's answering request can carry the *same* `requested_at` to the
  microsecond; `id` is random on a `binary_id` schema, so the tie-break would be
  a coin toss in precisely the case KTD19 is about.

  Read off that one row, the state machine is total:

    * neither `accepted_at` nor `declined_at` — pending. Whether it is *live* is
      a question about visibility at the asking instant, which nothing here
      stores.
    * `declined_at` — declined, and `blocked_initiator_id` is the requester.
    * `accepted_at` — accepted, and `peer_connections` holds the connection. If
      that connection has been closed, `blocked_initiator_id` names the
      counterpart of whoever closed it.

  ## `blocked_initiator_id` is KTD19, and it is a column rather than a rule

  "Fresh acceptance is directional": after a decline or a disconnect only the
  non-blocked party may send the next request, and **the block survives new
  co-rostering**. That last clause is why it is a column on this table and not a
  predicate over engagements — a block derived from employment would evaporate
  the moment the pair worked together again, which is the one thing the KTD says
  it must not do.

  Two check constraints keep the column honest without the application being
  asked to remember: it may only name a party to the request, and a *declined*
  row may only block its requester. The disconnect half cannot be checked here,
  because the party it blocks is decided on the other table.

  ## `peer_messages` names its author directly, and that is the difference

  `room_messages` resolves authorship through `engagements` (KTD15b), because it
  is an employer-zone row and may not name a human. This is a person-zone row
  between two people who need not be employed anywhere, so the engagement would
  be a key it could not always have. `author_id` references `people`, like
  everything else here.

  No retention column. KTD16's four triggers are U10's, and stamping a deadline
  before the sweeper that reads it exists would be a column nobody could test.

  ## `down` drops the three tables and takes everything with them

  Every index, constraint and generated column here belongs to one of them, in
  dependency order. The raw statement is `execute/1` rather than `execute/2` for
  the reason `create_engagements` and `create_rooms` give: a reverse handed to
  `execute/2` is only ever run by a reversing runner, and there is none here.
  """

  use Ecto.Migration

  # Long enough for a conversation, short enough that the column is not a file
  # upload with extra steps. The same bound `room_messages` carries.
  @max_body_length 4000

  def up do
    create_connection_requests()
    create_peer_connections()
    create_peer_messages()
  end

  # In dependency order, which is the reverse of `up`.
  def down do
    drop(table(:peer_messages))
    drop(table(:peer_connections))
    drop(table(:connection_requests))
  end

  ## Requests

  defp create_connection_requests do
    create table(:connection_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :requester_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :addressee_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :requested_at, :utc_datetime, null: false

      # At most one of these is set once the request has been answered, and
      # neither while it is outstanding.
      add :accepted_at, :utc_datetime
      add :declined_at, :utc_datetime

      # KTD19. Null while the pair has refused each other nothing.
      add :blocked_initiator_id, references(:people, type: :binary_id, on_delete: :restrict)

      # Set when a later request for the same pair replaces this one as the
      # pair's current row. See the moduledoc.
      add :superseded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The canonical spelling of an unordered pair, so a unique index has
    # something to be unique over. Generated rather than written, so no caller
    # can get it wrong.
    execute("""
    ALTER TABLE connection_requests
      ADD COLUMN pair_low_id uuid
      GENERATED ALWAYS AS (LEAST(requester_id, addressee_id)) STORED,
      ADD COLUMN pair_high_id uuid
      GENERATED ALWAYS AS (GREATEST(requester_id, addressee_id)) STORED
    """)

    create unique_index(:connection_requests, [:pair_low_id, :pair_high_id],
             where: "superseded_at IS NULL",
             name: :connection_requests_one_current_per_pair
           )

    create index(:connection_requests, [:requester_id, :requested_at, :id])
    create index(:connection_requests, [:addressee_id, :requested_at, :id])

    # A person is never co-rostered with themselves, so the application refuses
    # this before it arrives; the constraint is what makes that a property of
    # the schema rather than of one `with` clause.
    create constraint(:connection_requests, :connection_requests_two_people,
             check: "requester_id <> addressee_id"
           )

    create constraint(:connection_requests, :connection_requests_answered_once,
             check: "accepted_at IS NULL OR declined_at IS NULL"
           )

    # The block may only name somebody the request is between. Without it a
    # blocked-initiator column is a way to record a fact about a third party in
    # a row they are not in.
    create constraint(:connection_requests, :connection_requests_block_names_a_party,
             check:
               "blocked_initiator_id IS NULL OR " <>
                 "blocked_initiator_id IN (requester_id, addressee_id)"
           )

    # KTD19's decline half, in the schema. The disconnect half is decided on
    # `peer_connections` and cannot be checked from here.
    #
    # `IS NOT DISTINCT FROM` rather than `=`, and that is the whole constraint.
    # A CHECK is satisfied by NULL, and `NULL = requester_id` is NULL — so the
    # plain equality passed for a declined row whose `blocked_initiator_id` was
    # never written, which is exactly the row the constraint exists to refuse.
    # The invariant would have rested on `decline_request/2` writing both
    # columns in one statement rather than on the schema, which is the thing a
    # check constraint is for. `peer_connections_closure_complete` below is
    # NULL-proof by construction — paired `IS NULL` comparisons — so the shape
    # was already in this file when this one was written with a gap in it.
    create constraint(:connection_requests, :connection_requests_decline_blocks_requester,
             check:
               "declined_at IS NULL OR " <>
                 "blocked_initiator_id IS NOT DISTINCT FROM requester_id"
           )
  end

  ## Connections

  defp create_peer_connections do
    create table(:peer_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The approach this connection came out of, and the row the disconnect
      # writes its block on. Unique: one acceptance, one connection.
      add :request_id, references(:connection_requests, type: :binary_id, on_delete: :restrict),
        null: false

      add :person_a_id, references(:people, type: :binary_id, on_delete: :restrict), null: false
      add :person_b_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :connected_at, :utc_datetime, null: false

      # Null while the conversation is open. Nothing deletes the row: the
      # messages hang off it, and each party keeps their own (KTD21).
      add :disconnected_at, :utc_datetime
      add :disconnected_by_id, references(:people, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:peer_connections, [:request_id])

    # At most one live conversation per pair, whoever asked first. This is what
    # makes "simultaneous crossed requests resolve to one connection" a fact
    # about the database rather than a hope about the context.
    create unique_index(:peer_connections, [:person_a_id, :person_b_id],
             where: "disconnected_at IS NULL",
             name: :peer_connections_one_live_per_pair
           )

    create index(:peer_connections, [:person_a_id, :connected_at, :id])
    create index(:peer_connections, [:person_b_id, :connected_at, :id])

    # The pair, canonically. `connection_requests` generates its equivalent;
    # here the two columns are the row's identity rather than a projection of
    # it, so the ordering is a constraint and `HospitalityComs.Peers.Connection`
    # sorts on the way in.
    create constraint(:peer_connections, :peer_connections_pair_ordered,
             check: "person_a_id < person_b_id"
           )

    create constraint(:peer_connections, :peer_connections_disconnected_by_a_party,
             check:
               "disconnected_by_id IS NULL OR disconnected_by_id IN (person_a_id, person_b_id)"
           )

    # Both or neither: a closed conversation always says who closed it, and an
    # open one never does.
    create constraint(:peer_connections, :peer_connections_closure_complete,
             check: "(disconnected_at IS NULL) = (disconnected_by_id IS NULL)"
           )

    create constraint(:peer_connections, :peer_connections_closed_after_opened,
             check: "disconnected_at IS NULL OR disconnected_at >= connected_at"
           )
  end

  ## Messages

  defp create_peer_messages do
    create table(:peer_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :connection_id, references(:peer_connections, type: :binary_id, on_delete: :restrict),
        null: false

      # Directly, unlike `room_messages.author_engagement_id`. See the
      # moduledoc: a peer conversation outlives every engagement either party
      # holds, so an engagement is a key this row could not always have.
      add :author_id, references(:people, type: :binary_id, on_delete: :restrict), null: false

      add :body, :text, null: false
      add :sent_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # The history read, in the order it is read.
    create index(:peer_messages, [:connection_id, :sent_at, :id])

    # And the read a disconnected party gets: their own words, in the same
    # order.
    create index(:peer_messages, [:connection_id, :author_id, :sent_at, :id])

    create constraint(:peer_messages, :peer_messages_body_present,
             check: "length(btrim(body)) > 0"
           )

    create constraint(:peer_messages, :peer_messages_body_within_bound,
             check: "length(body) <= #{@max_body_length}"
           )
  end
end
