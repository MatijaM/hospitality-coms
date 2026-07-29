defmodule HospitalityComs.Repo.Migrations.AddDisplayNames do
  @moduledoc """
  `people.display_name` — the name a worker is given and can change, and the
  first readable thing about a human this schema has ever held.

  Issue #66. Before it, a venue room attributed a message to
  `author_engagement_id` and a client rendered the first eight characters of a
  UUID, because `people` carried exactly one column about a person and it was
  their email address. The two readable alternatives were both refused: the
  address, which is #65's founding case and `HospitalityComs.PeersTest` asserts
  the absence of; and the employer-authored `role_label`, which two people at
  one venue can share.

  ## What the zone gives for free, and what it does not

  `people` is **person zone**. `employer_role` holds nothing on it, this
  migration grants nothing, and `HospitalityComs.BoundaryTest`'s sweep asks
  `has_table_privilege` *and* `has_any_column_privilege` — so a new column is
  covered by construction and no new rule is needed. That is the whole of the
  employer side.

  What it does not give is anything about worker-to-worker disclosure. A
  globally stable readable name is a correlation key in the way
  `engagements.person_id` already is, and `HospitalityComs.Accounts.Person`'s
  moduledoc carries the sharp form of it.

  ## `NOT NULL`, and the backfill that makes it possible

  Nullable was the alternative and is worse: every read path would need a
  null-coalesce, which is the failure mode
  `HospitalityComs.Rooms.RoomMessage`'s moduledoc names as one of KTD15b's
  three reasons for putting the label on a row that is never nulled.

  So the column arrives nullable, is backfilled, and is then set `NOT NULL`.
  The backfill is **one statement**, deterministic on `md5(id)`, with the name
  list bound as a parameter read from
  `HospitalityComs.Accounts.DisplayName.all/0` rather than restated here — a
  list written twice is a list that disagrees with itself later.
  `*_create_employer_login_role.exs` reading `EmployerRepo.config/0` is the
  precedent for a migration reading a `lib` value.

  That list is a **backfill source and not a schema literal**, so it is not
  `test/hospitality_coms/constant_agreement_test.exs`'s business and may change
  freely afterwards. The *bound* below is, and has a row there.

  `substr(md5(...), 1, 7)` is 28 bits, so `::bit(28)::int` is non-negative and
  the modulus needs no `abs`. Eight hex characters would be `bit(32)`, which
  Postgres casts to a **signed** integer, and a negative subscript into a
  Postgres array is a valid index that selects nothing rather than an error.

  ## Two CHECKs, and neither is about erasure

  `people_display_name_present` and `people_display_name_within_bound` are
  `room_messages`' two constraints applied one table over, for the same reason:
  **the one write in the tree that reaches this column meets no changeset.**
  `HospitalityComs.Lifecycle.Records.pseudonymise/3` is an `update_all`, so a
  changeset validation is not consulted on the erasure path at all.

  There is deliberately **no** constraint holding `display_name` in opposition
  to `erased_at`, the way `people_erased_email_removed` and
  `people_present_email_required` hold the address. Three reasons, in
  `HospitalityComs.Accounts.Person`'s moduledoc; the short one is that those two
  exist to keep the *partial unique index* on `email` coherent, and this column
  has neither a unique index nor a presence/absence rule — it is overwritten
  with a value rather than removed.

  ## `down` restores the schema and loses every name

  Dropping the column destroys what people chose, and re-applying `up` gives
  everybody a fresh random character. That is invisible on an empty database and
  is the reason it is written here. There is nothing to capture first that would
  survive a second `up`, since the column is what would hold it.
  """

  use Ecto.Migration

  alias HospitalityComs.Accounts.DisplayName

  def up do
    alter table(:people) do
      add :display_name, :string
    end

    # Before the `NOT NULL`, and in its own step: `flush/0` is what makes the
    # ALTER above visible to the UPDATE below, which is a raw statement rather
    # than part of the migrator's own command buffer.
    flush()

    backfill()

    alter table(:people) do
      modify :display_name, :string, null: false
    end

    create constraint(:people, :people_display_name_present,
             check: "length(btrim(display_name)) > 0"
           )

    create constraint(:people, :people_display_name_within_bound,
             check: "length(display_name) <= #{DisplayName.max_length()}"
           )
  end

  def down do
    drop constraint(:people, :people_display_name_within_bound)
    drop constraint(:people, :people_display_name_present)

    alter table(:people) do
      remove :display_name
    end
  end

  defp backfill do
    names = DisplayName.all()

    repo().query!(
      """
      UPDATE people
      SET display_name =
        ($1::text[])[1 + (('x' || substr(md5(id::text), 1, 7))::bit(28)::int % $2::int)]
      WHERE display_name IS NULL
      """,
      [names, length(names)]
    )
  end
end
