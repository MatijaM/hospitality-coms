defmodule HospitalityComsWeb.ProfileChannelTest do
  @moduledoc """
  U9's contexts as a browser reaches them.

  ## What is asserted here rather than in `HospitalityComs.ProfilesTest`

  The context is where the disclosure rules are proved, and this file does not
  re-prove one of them. What a transport adds is the **envelope** —
  `client/src/features/profile/contract.ts` calls it exactly that — and the
  envelope is the part U9 could not settle because it had no transport: the
  topic, the event names, the wire casing, and which shape each reply carries.

  Every key set in this file is written out as a literal taken from
  `client/src/features/profile/decode.ts`, not derived from the struct on the
  other side of the comparison. That is deliberate: the client's decoders answer
  `null` rather than throwing, so a channel written to a different contract
  produces a surface that renders **empty and says nothing**, which on this
  surface is also a claim about somebody's working life.

  ## One test does what a browser does

  `"the surface the Profile tab loads"` joins the real topic on a real
  `HospitalityComsWeb.PersonSocket`, asks the two reads the client asks on join,
  and puts both replies through `Jason` — because `assert_reply` hands back the
  **Elixir term**, so a reply carrying a bare `%VisibleEntry{}` would satisfy
  every key-set assertion in this file and raise `Protocol.UndefinedError` in
  the serializer the first time a browser asked. That round trip is the only
  assertion here that can fail for an atom that should have been a string.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Accounts
  alias HospitalityComs.Engagements
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Peers
  alias HospitalityComs.PeersFixtures
  alias HospitalityComs.Profiles
  alias HospitalityComs.Rooms
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()

  # The wire shapes, copied out of `client/src/features/profile/decode.ts` field
  # for field. Literals rather than `Map.keys/1` of the struct they render,
  # because a comparison against the other side of the render is invariant under
  # every possible difference in it.
  @join_keys ~w(incompleteness_notice person_id)a
  @profile_keys ~w(attested_entries correction_requests declared_entries)a
  @entry_keys ~w(attested_at attested_entry_id ends_at entry_engagement_id role_label
                 starts_at venue_id venue_name)a
  @declaration_keys ~w(declared_at declared_entry_id ends_at organisation_name role_label
                       starts_at)a
  @correction_keys ~w(body correction_request_id entry_engagement_id requested_at resolution
                      resolved_at venue_id)a
  @disclosure_keys ~w(audience_id audience_kind decided_at disclosed disclosure_id
                      engagement_id)a
  # #73's picker. A venue listed **as itself** is `venue_id`/`name`, which is
  # `EmployerController.render_venue/1` and `RoomController.render_venue_room/1`
  # and both client decoders; `venue_name` is what a venue named *inside another
  # entity* is called, which `@entry_keys` above does and this is not.
  @audience_keys ~w(people venues)a
  @venue_audience_keys ~w(name venue_id)a
  @person_audience_keys ~w(display_name person_id)a

  describe "joining a profile surface" do
    test "replies with the person and the standing incompleteness notice" do
      worker = person()

      assert {:ok, reply, channel} = join_profile(worker)
      assert keys(reply) == @join_keys
      assert reply.person_id == worker.person.id
      assert channel.topic == "profile:" <> worker.person.id
    end

    test "and the notice is the context's constant, which is not empty" do
      # The control for the key set above: `incompleteness_notice: ""` has the
      # right key and no content, and an exact key set cannot tell.
      worker = person()

      {:ok, reply, _channel} = join_profile(worker)

      assert reply.incompleteness_notice == Profiles.incompleteness_notice()
      assert String.length(reply.incompleteness_notice) > 0
    end

    test "refuses a topic naming somebody else, and a suffix that is not an id" do
      # The repeated variable in `admitted/3` is the whole check. An `==` in a
      # body below is the same words and a different guarantee — and what is
      # behind this topic is every term somebody has served plus the list of
      # what they chose to conceal.
      worker = person()
      stranger = person()
      socket = person_socket(worker.person)

      assert {:error, somebody_else} =
               join(socket, "profile:" <> stranger.person.id, %{})

      assert {:error, malformed} = join(socket, "profile:not-a-uuid", %{})

      assert somebody_else.error.code == "unauthorized"
      assert somebody_else.error == malformed.error
    end

    test "while the same socket joins its own, which is the control" do
      # Every refusal above passes against a `join/3` that refused everything.
      worker = person()
      socket = person_socket(worker.person)

      assert {:ok, _reply, _channel} =
               subscribe_and_join(socket, "profile:" <> worker.person.id, %{})
    end
  end

  describe "the surface the Profile tab loads" do
    test "joins, reads the record and the ledger, and every reply survives Jason" do
      # #70's acceptance, as close as a channel test gets to a browser. The
      # `Jason` round trip is the half `assert_reply` cannot do: it reads the
      # Elixir term, so a struct on a reply passes every key-set assertion here
      # and raises inside the serializer the first time a client asks.
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()

      {:ok, joined, channel} = join_profile(worker)

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, _decided

      ref = push(channel, "profile", %{})
      assert_reply ref, :ok, profile

      ref = push(channel, "list_disclosures", %{})
      assert_reply ref, :ok, ledger

      wire_join = round_trip(joined)
      assert Map.keys(wire_join) |> Enum.sort() == ~w(incompleteness_notice person_id)
      assert wire_join["person_id"] == worker.person.id

      wire_profile = round_trip(profile)

      assert Map.keys(wire_profile) |> Enum.sort() ==
               ~w(attested_entries correction_requests declared_entries)

      # `decodeAttestedEntry` requires all eight, as strings.
      assert [entry | _rest] = wire_profile["attested_entries"]

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(attested_at attested_entry_id ends_at entry_engagement_id role_label
                  starts_at venue_id venue_name)

      assert Enum.all?(Map.values(entry), &is_binary/1)

      # `decodeDisclosure` narrows `audience_kind` against `AUDIENCE_KINDS`,
      # which is `["venue", "person"]` — strings. The channel sends the atom and
      # this is the step that turns it into one.
      wire_ledger = round_trip(ledger)
      assert [decision] = wire_ledger["disclosures"]
      assert decision["audience_kind"] == "venue"
      assert decision["audience_id"] == here.venue.id
      assert decision["disclosed"] == false
    end
  end

  describe "the worker's own record" do
    test "answers the three lists in the shapes the client decodes" do
      %{worker: worker, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref = push(channel, "declare_entry", draft())
      assert_reply ref, :ok, _declared

      ref =
        push(channel, "request_correction", %{
          "engagement_id" => engagement.id,
          "body" => "wrong dates"
        })

      assert_reply ref, :ok, _raised

      ref = push(channel, "profile", %{})
      assert_reply ref, :ok, profile

      assert keys(profile) == @profile_keys

      assert %{
               attested_entries: [entry | _more],
               declared_entries: [declaration],
               correction_requests: [correction]
             } = profile

      assert keys(entry) == @entry_keys
      assert keys(declaration) == @declaration_keys
      assert keys(correction) == @correction_keys
    end

    test "shows an entry the worker has concealed from a venue" do
      # `list_attested_entries/1` is explicit: disclosure governs what *others*
      # see, and a worker who could not see what they were hiding could not
      # decide about it. The disclosure controls are rendered per entry, so an
      # entry that vanished when it was hidden could never be un-hidden.
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, _decided

      ref = push(channel, "profile", %{})
      assert_reply ref, :ok, %{attested_entries: entries}

      assert engagement.id in Enum.map(entries, & &1.entry_engagement_id)
    end

    test "while the venue it was concealed from does not, which is the control" do
      # Without this the test above passes against a `set_disclosure` that wrote
      # nothing, against a fixture where the entry was never concealable, and
      # against a decision recorded for the wrong audience. Same entry, same
      # instant, the other door.
      %{worker: worker, here: here, viewer_engagement: viewer, entry_engagement: engagement} =
        concealable()

      channel = joined(worker)

      assert engagement.id in venue_sees(here, viewer)

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, _decided

      refute engagement.id in venue_sees(here, viewer)
    end
  end

  describe "the ledger" do
    test "renders an audience as a kind and an id, for both kinds" do
      # Never the table's two nullable columns, which put the XOR on the wire
      # for every consumer to re-derive, and never the tagged tuple, which no
      # JSON encoder can carry.
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()
      peer = person()
      channel = joined(worker)

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, to_venue

      ref =
        push(channel, "set_disclosure", %{
          "engagement_id" => engagement.id,
          "audience_kind" => "person",
          "audience_id" => peer.person.id,
          "disclosed" => true
        })

      assert_reply ref, :ok, to_person

      assert keys(to_venue) == @disclosure_keys
      assert to_venue.audience_kind == :venue
      assert to_venue.audience_id == here.venue.id
      assert to_venue.disclosed == false

      assert to_person.audience_kind == :person
      assert to_person.audience_id == peer.person.id
      assert to_person.disclosed == true

      refute Map.has_key?(to_venue, :audience_venue_id)
      refute Map.has_key?(to_person, :audience_person_id)

      ref = push(channel, "list_disclosures", %{})
      assert_reply ref, :ok, %{disclosures: decisions}

      assert MapSet.new(decisions, & &1.disclosure_id) ==
               MapSet.new([to_venue.disclosure_id, to_person.disclosure_id])
    end

    test "replaces an answer rather than adding a row when one pair is decided twice" do
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, hidden

      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, true))
      assert_reply ref, :ok, shown

      assert shown.disclosure_id == hidden.disclosure_id
      assert shown.disclosed == true

      ref = push(channel, "list_disclosures", %{})
      assert_reply ref, :ok, %{disclosures: [only]}
      assert only.disclosure_id == hidden.disclosure_id
    end

    test "refuses a decision about an engagement that is not this person's" do
      %{worker: worker, here: here} = concealable()
      %{entry_engagement: theirs} = concealable()

      channel = joined(worker)

      ref = push(channel, "set_disclosure", decision(theirs, here.venue.id, false))
      assert_reply ref, :error, refusal
      assert refusal.error.code == "not_found"
    end

    test "refuses an audience that is an id and names nothing by naming the field" do
      # The third answer this event can give, and the one `refusal-message.ts`
      # names: `Disclosure.declare_constraints/1` declares
      # `foreign_key_constraint(:audience_venue_id)`, so an id that is an id and
      # names no venue arrives as a changeset rather than as an
      # `Ecto.ConstraintError` out of a function whose spec enumerates one atom
      # and a changeset — which on one process carrying the whole surface would
      # be a crash rather than a refusal (KTD10).
      %{worker: worker, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref = push(channel, "set_disclosure", decision(engagement, Ecto.UUID.generate(), false))
      assert_reply ref, :error, refusal

      assert refusal.error.code == "unprocessable_entity"
      assert %{audience_venue_id: [_message | _more]} = refusal.error.fields

      assert Process.alive?(channel.channel_pid)
    end

    test "refuses an audience that is not one, without pretending it is an entry" do
      # `audience_kind` and `audience_id` are one value spelled as two fields, so
      # a pair that is not an audience is a malformed payload rather than a
      # missing row — and the `not_found` copy for this event reads "That entry
      # is not one of yours", which is a lie about a mistyped venue id.
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref =
        push(channel, "set_disclosure", %{
          "engagement_id" => engagement.id,
          "audience_kind" => "penguin",
          "audience_id" => here.venue.id,
          "disclosed" => false
        })

      assert_reply ref, :error, wrong_kind

      ref =
        push(channel, "set_disclosure", %{
          "engagement_id" => engagement.id,
          "audience_kind" => "venue",
          "audience_id" => "not-a-uuid",
          "disclosed" => false
        })

      assert_reply ref, :error, wrong_id

      assert wrong_kind.error.code == "bad_request"
      assert wrong_id.error.code == "bad_request"

      # The control: the same engagement, decided properly, is accepted. Both
      # refusals above pass against a channel that refuses every decision.
      ref = push(channel, "set_disclosure", decision(engagement, here.venue.id, false))
      assert_reply ref, :ok, _decided
    end
  end

  describe "a declared entry" do
    test "is written and comes back spelled declared_entry_id, never id" do
      # The schema says `id` because it is an Ecto schema; `VisibleDeclaration`
      # is what a reader gets, and `decodeDeclaredEntry` **refuses** `id` rather
      # than accepting either — so the schema on the wire renders an empty
      # surface that says nothing.
      channel = joined(person())

      ref = push(channel, "declare_entry", draft())
      assert_reply ref, :ok, written

      assert keys(written) == @declaration_keys
      refute Map.has_key?(written, :id)
      assert written.role_label == "Barback"
      assert written.organisation_name == "The Anchor"
    end

    test "is amended without re-declaring it" do
      # `declared_at` is the claim and an amendment is not a new one. The clock
      # moves between the two writes, so an implementation that restamped would
      # be visible.
      channel = joined(person())

      ref = push(channel, "declare_entry", draft())
      assert_reply ref, :ok, written

      at(DateTime.add(@now, 3, :day))

      ref =
        push(channel, "amend_declared_entry", %{
          "declared_entry_id" => written.declared_entry_id,
          "role_label" => "Head Barback",
          "organisation_name" => "The Anchor",
          "starts_at" => iso(days(-400)),
          "ends_at" => iso(days(-300))
        })

      assert_reply ref, :ok, amended

      assert keys(amended) == @declaration_keys
      assert amended.declared_entry_id == written.declared_entry_id
      assert amended.role_label == "Head Barback"
      assert amended.declared_at == written.declared_at
    end

    test "answers somebody else's entry, an id naming nothing, and a malformed id alike" do
      # AE1 at the transport. Uncast, the malformed one reaches Ecto's query
      # builder and raises, which the transport reports as a crash — so a caller
      # could tell it from an unknown id by which answer they got.
      mine = joined(person())
      theirs = joined(person())

      ref = push(theirs, "declare_entry", draft())
      assert_reply ref, :ok, %{declared_entry_id: not_mine}

      ref = push(mine, "amend_declared_entry", amendment(not_mine))
      assert_reply ref, :error, somebody_elses

      ref = push(mine, "amend_declared_entry", amendment(Ecto.UUID.generate()))
      assert_reply ref, :error, nothing

      ref = push(mine, "amend_declared_entry", amendment("not-a-uuid"))
      assert_reply ref, :error, malformed

      assert somebody_elses.error.code == "not_found"
      assert somebody_elses.error == nothing.error
      assert nothing.error == malformed.error

      assert Process.alive?(mine.channel_pid)
    end

    test "refuses a blank label by naming the field rather than the payload" do
      # Worker-authored text goes to the changeset so the refusal names the
      # input the worker filled in — which is what the form renders it beside. A
      # `bad_request` here would throw that away.
      channel = joined(person())

      ref = push(channel, "declare_entry", %{draft() | "role_label" => "   "})
      assert_reply ref, :error, refusal

      assert refusal.error.code == "unprocessable_entity"
      assert %{role_label: [_message | _more]} = refusal.error.fields
    end
  end

  describe "a correction request" do
    test "comes back as the same shape the record's own list carries" do
      # `request_correction/3` used to answer the schema while its four readers
      # answered `VisibleCorrection`, so one entity was `id` with
      # `resolution: "declined"` when written and `correction_request_id` with
      # `:declined` when read. Compared as whole maps rather than as key sets:
      # two maps built by one render function have the same keys by
      # construction, and the values are what say it is the same row.
      %{worker: worker, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref =
        push(channel, "request_correction", %{
          "engagement_id" => engagement.id,
          "body" => "those dates are wrong"
        })

      assert_reply ref, :ok, written

      assert keys(written) == @correction_keys
      refute Map.has_key?(written, :id)
      assert written.resolved_at == nil
      assert written.resolution == nil

      ref = push(channel, "profile", %{})
      assert_reply ref, :ok, %{correction_requests: [listed]}

      assert written == listed
    end

    test "refuses an engagement that is not this person's" do
      %{worker: worker} = concealable()
      %{entry_engagement: theirs} = concealable()

      channel = joined(worker)

      ref =
        push(channel, "request_correction", %{
          "engagement_id" => theirs.id,
          "body" => "not mine to contest"
        })

      assert_reply ref, :error, refusal
      assert refusal.error.code == "not_found"
    end

    test "refuses a blank body by naming the field" do
      %{worker: worker, entry_engagement: engagement} = concealable()
      channel = joined(worker)

      ref = push(channel, "request_correction", %{"engagement_id" => engagement.id, "body" => ""})
      assert_reply ref, :error, refusal

      assert refusal.error.code == "unprocessable_entity"
      assert %{body: [_message | _more]} = refusal.error.fields
    end
  end

  describe "a peer's record" do
    test "is the same three lists the worker's own read answers" do
      %{first: viewer, second: subject} = PeersFixtures.co_rostered(@now)
      channel = joined(viewer)

      ref = push(channel, "peer_profile", %{"person_id" => subject.person.id})
      assert_reply ref, :ok, profile

      assert keys(profile) == @profile_keys
      assert %{attested_entries: [entry | _more]} = profile
      assert keys(entry) == @entry_keys
    end

    test "carries no ledger, and there is no event that would give a viewer one" do
      # What a worker has decided about their own record is theirs. The exact
      # key set is what fails when a field is *added*, which is the direction a
      # `disclosures` key would arrive from.
      %{first: viewer, second: subject} = PeersFixtures.co_rostered(@now)
      channel = joined(viewer)

      ref = push(channel, "peer_profile", %{"person_id" => subject.person.id})
      assert_reply ref, :ok, profile

      refute Map.has_key?(profile, :disclosures)
      refute Map.has_key?(profile, :incompleteness_notice)
      assert keys(profile) == @profile_keys

      # The control: the same channel *does* answer this person's own ledger, so
      # the absence above is not "nothing exists".
      ref = push(channel, "list_disclosures", %{})
      assert_reply ref, :ok, %{disclosures: _theirs}
    end

    test "is still readable by somebody connected once visibility has lapsed" do
      # The gate is visible **or** connected, and the two clauses are not
      # redundant: visibility lapses thirty days past the first engagement to
      # end, while a connection is permanent. A `Peers.visible?/2` in front of
      # the context would compile and take the profile away from two people
      # still in conversation.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: viewer, second: subject} =
        PeersFixtures.co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      PeersFixtures.connection_fixture(viewer, subject)

      channel = joined(viewer)

      at(DateTime.add(ends_at, 31, :day))

      lapsed = PeersFixtures.person_at(viewer, DateTime.add(ends_at, 31, :day))
      refute Peers.visible?(lapsed, subject.person.id)

      ref = push(channel, "peer_profile", %{"person_id" => subject.person.id})
      assert_reply ref, :ok, profile
      assert keys(profile) == @profile_keys
    end

    test "answers a stranger, the caller themselves, and an id naming nobody alike" do
      # The control for the test above: a channel that gated on nothing would
      # satisfy it completely.
      %{first: viewer} = PeersFixtures.co_rostered(@now)
      %{first: stranger} = PeersFixtures.co_rostered(@now)

      channel = joined(viewer)

      ref = push(channel, "peer_profile", %{"person_id" => stranger.person.id})
      assert_reply ref, :error, not_a_peer

      ref = push(channel, "peer_profile", %{"person_id" => viewer.person.id})
      assert_reply ref, :error, themselves

      ref = push(channel, "peer_profile", %{"person_id" => Ecto.UUID.generate()})
      assert_reply ref, :error, nobody

      ref = push(channel, "peer_profile", %{"person_id" => "not-a-uuid"})
      assert_reply ref, :error, malformed

      assert not_a_peer.error.code == "not_found"
      assert not_a_peer.error == themselves.error
      assert themselves.error == nobody.error
      assert nobody.error == malformed.error
    end
  end

  describe "the instant is the event's, not the join's (KTD5)" do
    test "refuses a peer read once visibility has run out while the channel lived" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: viewer, second: subject} =
        PeersFixtures.co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      channel = joined(viewer)

      # The control: it worked a moment ago, on this same channel, with no
      # rejoin between the two pushes.
      ref = push(channel, "peer_profile", %{"person_id" => subject.person.id})
      assert_reply ref, :ok, _profile

      at(DateTime.add(ends_at, 31, :day))

      ref = push(channel, "peer_profile", %{"person_id" => subject.person.id})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "not_found"
    end
  end

  describe "the audience picker" do
    # #73. `set_disclosure` names an audience that is a venue **or** a person,
    # and until this event nothing on the surface could say which venues or
    # which people one might be — so the control made the worker type a raw
    # uuid.

    test "answers the venues this worker holds an engagement at and the people who can see them" do
      %{worker: worker, here: here} = concealable()
      colleague = person()
      engage(here, colleague, @now, days(30))
      {:ok, _renamed} = Accounts.update_display_name(colleague, "Captain Nemo")

      channel = joined(worker)

      ref = push(channel, "list_audiences", %{})
      assert_reply ref, :ok, audiences

      assert keys(audiences) == @audience_keys
      assert [venue] = audiences.venues
      assert [person] = audiences.people

      assert keys(venue) == @venue_audience_keys
      assert venue.venue_id == here.venue.id
      assert venue.name == here.venue.name

      assert keys(person) == @person_audience_keys
      assert person.person_id == colleague.person.id
      assert person.display_name == "Captain Nemo"
    end

    test "offers a venue this worker manages nothing at, and one they are suspended from" do
      # The two lists this is *not*. `Engagements.list_managed_venues/1` needs a
      # live grant, so an ordinary worker's picker would be empty at the venue
      # that can actually read their record; `Rooms.list_venue_rooms/1`
      # subtracts suspensions, which are a person-side venue-room opt-out that
      # the employer view has never heard of (KTD18).
      %{worker: worker, here: here} = concealable()
      {:ok, _suspension} = Rooms.suspend_venue_room(worker, here.venue.id)

      channel = joined(worker)

      ref = push(channel, "list_audiences", %{})
      assert_reply ref, :ok, audiences

      assert [%{venue_id: venue_id}] = audiences.venues
      assert venue_id == here.venue.id

      # The two controls, at the same instant: the venue is genuinely
      # ungoverned by this worker and genuinely out of their room list.
      assert Engagements.list_managed_venues(worker) == []
      assert Rooms.list_venue_rooms(worker) == []
    end

    test "offers a connected peer whose visibility has lapsed" do
      # The half that makes the picker able to reach the remedy it exists for:
      # the person a worker most wants to take an entry away from is one who is
      # connected and no longer co-rostered, because a connection outlives the
      # visibility that produced it and `fetch_peer_profile/2` admits them.
      %{first: worker, second: peer} =
        PeersFixtures.co_rostered(@now, %{
          first: %{starts_at: days(-100), ends_at: days(-90)},
          second: %{starts_at: days(-100), ends_at: days(-90)}
        })

      {:ok, _renamed} = Accounts.update_display_name(peer, "Captain Nemo")

      # Formed while they could still see each other; asked long after, which is
      # the state this row is about.
      PeersFixtures.connection_fixture(
        PeersFixtures.person_at(worker, days(-95)),
        PeersFixtures.person_at(peer, days(-95))
      )

      refute Peers.visible?(worker, peer.person.id)
      assert Peers.connected?(worker, peer.person.id)

      channel = joined(worker)

      ref = push(channel, "list_audiences", %{})
      assert_reply ref, :ok, audiences

      # No venue: the term is long over, which is the same instant that lapsed
      # the visibility. The person is here anyway.
      assert audiences.venues == []
      assert [%{person_id: person_id, display_name: "Captain Nemo"}] = audiences.people
      assert person_id == peer.person.id
    end

    test "offers a stranger's venue in neither list" do
      # The control for both rows above: a picker that answered everything
      # satisfies each of them completely.
      %{worker: worker, here: here} = concealable()
      %{first: stranger} = PeersFixtures.co_rostered(@now)

      channel = joined(worker)

      ref = push(channel, "list_audiences", %{})
      assert_reply ref, :ok, audiences

      assert Enum.map(audiences.venues, & &1.venue_id) == [here.venue.id]
      refute Enum.any?(audiences.people, &(&1.person_id == stranger.person.id))
    end

    test "hands back ids `set_disclosure` accepts, of both kinds, and survives Jason" do
      # A picker whose ids the write refuses is not a picker. Both kinds, in one
      # test, because the pair is what `Disclosure.audience/0` is.
      #
      # The `Jason` round trip is the assertion `assert_reply` cannot make: it
      # reads the Elixir term, so a struct on the reply passes every key set
      # above and raises inside the serializer the first time a browser asks.
      %{worker: worker, here: here, entry_engagement: engagement} = concealable()
      colleague = person()
      engage(here, colleague, @now, days(30))

      channel = joined(worker)

      ref = push(channel, "list_audiences", %{})
      assert_reply ref, :ok, audiences

      wire = round_trip(audiences)
      assert Map.keys(wire) |> Enum.sort() == ~w(people venues)
      assert [%{"venue_id" => wire_venue_id, "name" => _}] = wire["venues"]
      assert [%{"person_id" => wire_person_id, "display_name" => _}] = wire["people"]

      ref =
        push(channel, "set_disclosure", %{
          "engagement_id" => engagement.id,
          "audience_kind" => "venue",
          "audience_id" => wire_venue_id,
          "disclosed" => false
        })

      assert_reply ref, :ok, hidden_from_venue
      assert hidden_from_venue.audience_kind == :venue
      assert hidden_from_venue.audience_id == here.venue.id

      ref =
        push(channel, "set_disclosure", %{
          "engagement_id" => engagement.id,
          "audience_kind" => "person",
          "audience_id" => wire_person_id,
          "disclosed" => false
        })

      assert_reply ref, :ok, hidden_from_person
      assert hidden_from_person.audience_kind == :person
      assert hidden_from_person.audience_id == colleague.person.id
    end
  end

  describe "one process carrying the whole surface (KTD10)" do
    test "answers an event it does not handle rather than crashing on it" do
      channel = joined(person())

      ref = push(channel, "delete_everything", %{"really" => true})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"

      assert Process.alive?(channel.channel_pid)
    end

    test "ignores a message no clause matches rather than dying on it" do
      # Nothing publishes to this topic today, so this catches only strays — but
      # exporting `handle_info/2` at all opts out of Phoenix's warn-and-ignore,
      # and the day something does publish here the clause added for it will do
      # exactly that. An unhandled message then takes the record, the ledger and
      # the open peer profile down at once.
      channel = joined(person())

      send(channel.channel_pid, {:something_else, %{}})

      ref = push(channel, "profile", %{})
      assert_reply ref, :ok, _profile
      assert Process.alive?(channel.channel_pid)
    end

    test "tells a caller which of its payloads was short, rather than one sentence for all" do
      # `set_disclosure` needs four values, so falling through to the id-only
      # message would tell a client that supplied a perfectly good
      # `engagement_id` that the id is the problem. The assertion that carries it
      # is that the two bodies are **unequal**.
      channel = joined(person())

      ref = push(channel, "set_disclosure", %{})
      assert_reply ref, :error, decision

      ref = push(channel, "amend_declared_entry", %{})
      assert_reply ref, :error, id_only

      ref = push(channel, "declare_entry", "not an object")
      assert_reply ref, :error, draft

      assert decision.error.code == "bad_request"
      assert id_only.error.code == "bad_request"
      assert draft.error.code == "bad_request"

      refute decision.error == id_only.error
      refute draft.error == id_only.error

      assert Process.alive?(channel.channel_pid)
    end
  end

  ## Fixtures

  defp days(count), do: DateTime.add(@now, count, :day)

  defp iso(instant), do: DateTime.to_iso8601(instant)

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp person, do: EngagementsFixtures.person_scope_fixture(@now)

  defp venue do
    {employer, creation} = EngagementsFixtures.scoped_venue_fixture(@now)
    %{employer: employer, venue: creation.venue, grant: creation.grant}
  end

  defp engage(place, worker, from, to) do
    EngagementsFixtures.engagement_fixture(place.employer, worker, %{
      role_label: "Bartender",
      starts_at: from,
      ends_at: to,
      code_expires_at: DateTime.add(place.employer.now, 7, :day)
    })
  end

  # One worker, two venues, **non-overlapping** terms — so the concurrency
  # default *discloses* the older entry to the current venue and a ledger row is
  # the only thing that can take it away. Overlapping terms would hide it by
  # default and the control below would pass for the wrong reason.
  defp concealable do
    elsewhere = venue()
    here = venue()
    worker = person()

    entry_engagement = engage(elsewhere, worker, days(-100), days(-50))
    viewer_engagement = engage(here, worker, @now, days(30))

    %{
      worker: worker,
      here: here,
      elsewhere: elsewhere,
      entry_engagement: entry_engagement,
      viewer_engagement: viewer_engagement
    }
  end

  # The other door: what the venue itself can read about this worker, through
  # the owner-privileged view and `HospitalityComs.EmployerRepo`.
  defp venue_sees(place, viewer_engagement) do
    {:ok, entries} =
      Profiles.list_visible_entries(
        EngagementsFixtures.employer_scope_fixture(
          %{venue: place.venue, grant: place.grant},
          @now
        ),
        viewer_engagement.id
      )

    Enum.map(entries, & &1.entry_engagement_id)
  end

  defp decision(engagement, venue_id, disclosed) do
    %{
      "engagement_id" => engagement.id,
      "audience_kind" => "venue",
      "audience_id" => venue_id,
      "disclosed" => disclosed
    }
  end

  defp draft do
    %{
      "role_label" => "Barback",
      "organisation_name" => "The Anchor",
      "starts_at" => iso(days(-400)),
      "ends_at" => iso(days(-300))
    }
  end

  defp amendment(entry_id), do: Map.put(draft(), "declared_entry_id", entry_id)

  # What a browser gets, rather than what `assert_reply` gets. `Jason` is the
  # configured `:json_library`, so this is the same encoder
  # `Phoenix.Socket.V2.JSONSerializer` uses.
  defp round_trip(reply), do: reply |> Jason.encode!() |> Jason.decode!()

  defp joined(scope) do
    {:ok, _reply, channel} = join_profile(scope)
    channel
  end

  defp join_profile(scope) do
    scope.person
    |> person_socket()
    |> subscribe_and_join("profile:" <> scope.person.id, %{})
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
    socket
  end
end
