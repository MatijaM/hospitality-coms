defmodule HospitalityComs.Accounts.DisplayName do
  @moduledoc """
  The names a person is *given* at registration, and the bound on the one they
  choose instead.

  ## Why a given name rather than an asked-for one

  `people` has exactly one identifying column, `email`, and this application
  never asks for another. A worker who has just followed a magic link has
  supplied one fact about themselves and is owed a way to be recognised in a
  room without supplying a second — so the name arrives already set, and
  changing it is an option rather than a step.

  ## Why fictional characters, and why these ones

  Two properties, and both are requirements rather than flavour.

  **A generated name must not read as a real person's.** Anything drawn from a
  list of ordinary forenames and surnames produces "Sarah Whitfield", which a
  person looking at a demo reads as somebody's actual identity — and this
  product's whole argument is about not putting one of those on a screen by
  accident. A recognisable character does not have that failure mode.

  **They are public domain.** Sherlock Holmes and Wendy Darling cannot become a
  licensing question the way a character from a living franchise could.

  ## Collisions are allowed, and that is a privacy decision

  Nothing here is unique and no index makes it so. The cheap argument is that
  the venue room's roll already carries `author_engagement_id` beside every
  message, so a repeated name is disambiguated by something already on the wire,
  and a name is not an authorisation.

  The argument that settles it runs the other way. `CLAUDE.md` records
  `engagements.person_id` as a globally stable key two venues could compare out
  of band. **A globally unique display name would be a second such key, in plain
  text, readable by every worker rather than only by somebody holding a
  database connection.** Collisions are the only thing that stops "Captain Nemo"
  being as good as a person id, so uniqueness is refused rather than merely not
  bought.

  Sixty-four names is enough that a small venue rarely collides and large enough
  that nobody should read the name as an identifier.
  """

  # Public-domain literary characters, each unmistakably fictional. Sixty-four,
  # which is a number rather than a constraint: nothing derives from it and
  # `HospitalityComs.AccountsTest` asserts the list's properties rather than its
  # length.
  @names [
    "Sherlock Holmes",
    "Long John Silver",
    "Ebenezer Scrooge",
    "Robinson Crusoe",
    "Lemuel Gulliver",
    "Don Quixote",
    "Sancho Panza",
    "Ichabod Crane",
    "Rip Van Winkle",
    "Captain Nemo",
    "Phileas Fogg",
    "Allan Quatermain",
    "Dorian Gray",
    "Abraham Van Helsing",
    "Captain Ahab",
    "Queequeg",
    "Natty Bumppo",
    "Tom Sawyer",
    "Huckleberry Finn",
    "Becky Thatcher",
    "Jim Hawkins",
    "The Mad Hatter",
    "The Cheshire Cat",
    "The White Rabbit",
    "Peter Pan",
    "Wendy Darling",
    "Captain Hook",
    "Tinker Bell",
    "Dorothy Gale",
    "The Tin Woodman",
    "The Cowardly Lion",
    "The Scarecrow",
    "Anne Shirley",
    "Pollyanna Whittier",
    "Pinocchio",
    "Geppetto",
    "Cyrano de Bergerac",
    "D'Artagnan",
    "Athos",
    "Porthos",
    "Aramis",
    "Edmond Dantes",
    "Jean Valjean",
    "Inspector Javert",
    "Quasimodo",
    "La Esmeralda",
    "Oliver Twist",
    "The Artful Dodger",
    "Miss Havisham",
    "Uriah Heep",
    "Wilkins Micawber",
    "Elizabeth Bennet",
    "Emma Woodhouse",
    "Jane Eyre",
    "Heathcliff",
    "Sydney Carton",
    "Madame Defarge",
    "Puck",
    "Prospero",
    "Caliban",
    "Falstaff",
    "Rosalind",
    "Malvolio",
    "Portia"
  ]

  # The longest a chosen name may be, in characters.
  #
  # Declared here and again as `people_display_name_within_bound` in
  # `*_add_display_names.exs`, because a migration literal can neither be
  # edited nor derived — so the pair gets a test rather than a derivation
  # (issue #42, and `test/hospitality_coms/constant_agreement_test.exs` is where
  # the CHECK is read back out of `pg_constraint` and compared against this).
  #
  # **No relation is asserted to `HospitalityComs.Engagements.Invitation.max_label_length/0`**,
  # which is 160. A job title and a name somebody calls themselves are different
  # things, and a linking sentence between two numbers nothing checks is how
  # they drift — `HospitalityComs.Profiles.DeclaredEntry` said exactly such a
  # sentence over a wrong number for the life of a unit.
  @max_length 60

  @doc """
  Every name a registration may draw.

  Public so that the backfill in `*_add_display_names.exs` can bind it as a
  query parameter rather than restate it: a list written twice is a list that
  disagrees with itself later.
  """
  @spec all() :: [String.t(), ...]
  def all, do: @names

  @doc """
  One of them, chosen at random.

  No uniqueness check and no retry: see the moduledoc. `Enum.random/1` reads the
  process's seed and no clock, so this is not a `HospitalityComs.Clock` caller.
  """
  @spec generate() :: String.t()
  def generate, do: Enum.random(@names)

  @doc """
  The longest name the schema and the database accept, in characters.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length
end
