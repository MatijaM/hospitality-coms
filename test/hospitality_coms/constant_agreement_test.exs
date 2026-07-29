defmodule HospitalityComs.ConstantAgreementTest do
  @moduledoc """
  The pairs of numbers that must agree, and a check that reads both sides.

  Issue #42 swept `lib/`, `config/` and `priv/repo/migrations/` for values that
  are declared twice and linked by a comment. One had already drifted:
  `declared_entries.role_label` said *"the same bound `engagements.role_label`
  carries"* and carried 120 where that column carries 160, and nothing noticed
  because the sentence was not checkable.

  ## Why this file exists rather than a compile-time derivation

  Most of those pairs have a migration literal on one side, and `AGENTS.md`
  forbids editing one: a migration has to replay to the schema it originally
  produced. So `Application.compile_env/3` and a module attribute reading
  another module's export are both unavailable, and the honest mechanism is to
  ask Postgres what the constraint actually says and compare that against the
  module constant claiming to describe it.

  That is not the weaker option here; it reaches something derivation cannot.
  Deriving `Peers.PeerMessage`'s bound from `Rooms.RoomMessage`'s would make two
  Elixir constants agree and leave the four database CHECKs — the things that
  are actually enforced, and the things that have already drifted once —
  unchecked.

  ## It cannot agree with itself

  `docs/solutions/test-failures/tests-that-certify-nothing.md` names the shape
  to avoid: an equality whose two sides are derived from one source passes for
  any value, including a wrong one. Here one side is an Elixir module attribute
  and the other is a string Postgres generates from a `pg_constraint` row
  written by a migration. There is no path by which one produces the other.

  What *is* a risk is the reader. A helper that answered `nil` for a constraint
  name nobody spelled correctly would make every assertion below pass against
  `nil == nil`, and every one of these names is a long string no reviewer
  re-reads. So the reader raises on a name that matches nothing, and there is a
  test for that, plus one that shows it returning two different numbers for two
  different constraints.

  ## The one deliberate literal

  `the three anchors the database holds` writes 160, 14 and 4000 out by hand.
  Every other assertion compares the database against a module, so a change made
  in *both* places passes all of them; the anchor test is the one somebody has
  to edit on purpose. It is the same manoeuvre
  `test/hospitality_coms/workers/retention_sweeper_test.exs` makes with literal
  day counts and `boundary_test.exs` makes by writing the zone tables out — a
  test that pins a value must be able to disagree with it.
  """

  use HospitalityComs.DataCase, async: true

  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Profiles.CorrectionRequest
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Rooms.RoomMessage

  # Everything on `retention_runs` that is not a trigger's count. Written out
  # here rather than derived so that this file can disagree with the schema,
  # which is the whole point of the assertion it serves.
  @non_count_fields [:id, :ran_at, :outcome, :ceiling, :inserted_at, :updated_at]

  describe "role label bounds" do
    test "the declared-entry label bound is the bound engagements.role_label carries" do
      # Issue #42's item 1, and the one that had already drifted. The comment on
      # `DeclaredEntry.@max_label_length` claims this equality; before #42 it was
      # 120 against 160 and had been for two units.
      assert length_bound("declared_entries_role_label_within_bound") ==
               DeclaredEntry.max_label_length()

      assert length_bound("engagements_role_label_within_bound") ==
               Invitation.max_label_length()
    end

    test "an organisation name is bounded by the same number the label is" do
      # One module attribute governs both validations, so one bound governs both
      # columns. Splitting them would be a second declaration bought to avoid a
      # one-line migration.
      assert length_bound("declared_entries_organisation_within_bound") ==
               DeclaredEntry.max_label_length()
    end

    test "an invitation's label bound is the one its changeset enforces" do
      # `Invitation` is where the number is declared and `Engagement` already
      # reads it, so this is the only one of the four label bounds whose two
      # sides were linked before #42 — by a function call rather than a comment.
      assert length_bound("invitations_role_label_within_bound") ==
               Invitation.max_label_length()
    end
  end

  describe "the claim code horizon" do
    test "the database refuses exactly the codes the changeset refuses" do
      # Issue #42's item 3. `Invitation.@max_code_validity_in_days` and the CHECK
      # in `*_create_engagements.exs` are two declarations of one number, and
      # raising the module constant leaves the whole suite green while the
      # database silently refuses codes the changeset has accepted — the
      # changeset tests in `engagements_test.exs` derive their input from the
      # constant, so they move with it.
      assert interval_days("invitations_code_expiry_within_bound") ==
               Invitation.max_code_validity_in_days()
    end
  end

  describe "message body bounds" do
    test "every body bound the database enforces is the one its changeset enforces" do
      # Issue #42's item 5. Three modules declare 4000 independently and nothing
      # requires them to agree with *each other* — so each is pinned to its own
      # table rather than to a sibling, which also covers the four migration
      # literals that a cross-module derivation would leave untouched.
      assert length_bound("room_messages_body_within_bound") == RoomMessage.max_body_length()
      assert length_bound("peer_messages_body_within_bound") == PeerMessage.max_body_length()

      assert length_bound("correction_requests_body_within_bound") ==
               CorrectionRequest.max_body_length()
    end

    test "a retained copy can hold any message it is a copy of" do
      # Item 5's sharpest instance, and the only body-length relation that is
      # real rather than claimed. `Lifecycle.RetainedMessageCopy` has no length
      # validation and is written with `insert_all`, so its CHECK is reached with
      # no changeset in front of it: a room-message bound raised past this one
      # would raise `Postgrex.Error` inside the retention transaction rather than
      # returning a changeset error.
      #
      # Asserted as an ordering rather than an equality because that is the
      # relation. A retained copy may be allowed to be longer than its source;
      # it may never be allowed to be shorter.
      assert length_bound("retained_message_copies_body_within_bound") >=
               RoomMessage.max_body_length()
    end
  end

  describe "the numbers themselves" do
    test "the three anchors the database holds are 160, 14 and 4000" do
      # The one assertion in this file that does not derive either side from a
      # module. Everything above compares the database against Elixir, so a
      # change made in both places at once passes all of it; this is the line
      # somebody has to edit deliberately, and editing it is what puts the
      # number in front of a reviewer.
      assert length_bound("engagements_role_label_within_bound") == 160
      assert length_bound("declared_entries_role_label_within_bound") == 160
      assert interval_days("invitations_code_expiry_within_bound") == 14
      assert length_bound("room_messages_body_within_bound") == 4000
    end
  end

  describe "the reader" do
    test "raises rather than answering nil for a constraint that does not exist" do
      # The vacuity control for every assertion above. Ten long constraint names
      # go through this helper and nobody re-reads them; a reader that answered
      # `nil` on a typo would make each of those assertions compare `nil`
      # against `nil` and pass.
      assert_raise RuntimeError, ~r/no_such_constraint/, fn ->
        length_bound("no_such_constraint")
      end

      assert_raise RuntimeError, ~r/no_such_constraint/, fn ->
        interval_days("no_such_constraint")
      end
    end

    test "answers different numbers for constraints that hold different numbers" do
      # The discrimination control. A helper that returned a constant — 160, say,
      # or whatever the first row happened to be — would pass every label
      # assertion above. Two live bounds that genuinely differ is what rules
      # that out.
      assert length_bound("engagements_role_label_within_bound") !=
               length_bound("room_messages_body_within_bound")
    end

    test "raises when a definition is not the shape it is being read as" do
      # The label reader against an interval constraint. Without this, a parser
      # whose regex silently failed to match would need a second bug to be
      # noticed at all.
      assert_raise RuntimeError, ~r/invitations_code_expiry_within_bound/, fn ->
        length_bound("invitations_code_expiry_within_bound")
      end
    end
  end

  describe "the retention sweep's two bounds" do
    test "the trigger list is every count the run record keeps" do
      # Issue #42's item 4, second half: "four triggers" was a prose literal in
      # three places, so a fifth trigger would have invalidated the ceiling
      # argument silently. A trigger is a thing that gets its own count, so the
      # list is pinned to the columns the run record stores them in.
      # Sorted on both sides: `__schema__(:fields)` returns declaration order,
      # so a bare list equality also pins where a column sits in the schema.
      # Reordering two fields would then fail this test for a reason it does
      # not name, which is how a test stops being read as the claim it makes.
      assert Enum.sort(RetentionRun.triggers()) ==
               Enum.sort(RetentionRun.__schema__(:fields) -- @non_count_fields)
    end

    test "an ordinary run cannot reach the ceiling" do
      # Item 4's first half, applied to the *effective* settings rather than the
      # defaults. `Lifecycle`'s compile-time raise covers `@default_batch_size`
      # and `@default_ceiling`; `batch_size/0` and `ceiling/0` read
      # `config/config.exs` at runtime and nothing at compile time can see those.
      #
      # The ceiling is a guard against a missing batch bound, not a throttle. A
      # ceiling an ordinary run could hit would roll the same rows back on every
      # tick and the sweep would never make progress again.
      assert Lifecycle.batch_size() * length(RetentionRun.triggers()) < Lifecycle.ceiling()
    end
  end

  # The number a `length(...) <= n` CHECK enforces, read from the definition
  # Postgres generates rather than from anything this application wrote.
  @spec length_bound(String.t()) :: pos_integer()
  defp length_bound(name) do
    name |> definition() |> capture(~r/<= (\d+)\)/, name, "a length bound")
  end

  # The number of days an `x <= y + interval 'n days'` CHECK allows. Postgres
  # normalises the literal, and renders a one-day interval as `'1 day'`.
  @spec interval_days(String.t()) :: pos_integer()
  defp interval_days(name) do
    name |> definition() |> capture(~r/'(\d+) days?'::interval/, name, "an interval in days")
  end

  @spec capture(String.t(), Regex.t(), String.t(), String.t()) :: pos_integer()
  defp capture(definition, pattern, name, shape) do
    pattern |> Regex.run(definition) |> integer(definition, name, shape)
  end

  @spec integer([String.t()] | nil, String.t(), String.t(), String.t()) :: pos_integer()
  defp integer([_whole, digits], _definition, _name, _shape), do: String.to_integer(digits)

  defp integer(nil, definition, name, shape) do
    raise "#{name} does not read as #{shape}: #{definition}"
  end

  @spec definition(String.t()) :: String.t()
  defp definition(name) do
    Repo.query!(
      "select pg_get_constraintdef(oid) from pg_constraint where conname = $1",
      [name]
    ).rows
    |> only(name)
  end

  @spec only([[String.t()]], String.t()) :: String.t()
  defp only([[definition]], _name), do: definition

  defp only(rows, name) do
    raise "expected exactly one constraint named #{name}, found #{length(rows)}"
  end
end
