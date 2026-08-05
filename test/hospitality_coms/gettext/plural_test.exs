defmodule HospitalityComs.Gettext.PluralTest do
  @moduledoc """
  Serbian's three plural forms, at the counts where they change.

  This file exists because a wrong plural rule is invisible to every other kind
  of assertion. A test that checks *which message came back* passes whether the
  count picked form one, two or three — the string is grammatical either way and
  simply wrong, which is the failure mode a reader notices and a suite does not.

  So the boundaries are named individually rather than swept: 1 and 21 against
  11, 2–4 and 22–24 against 12–14, and 0 and 5 as the ordinary case. Those are
  the exact counts the rule's three clauses hinge on.
  """

  use ExUnit.Case, async: true

  alias HospitalityComs.Gettext.Plural

  @one 0
  @few 1
  @other 2

  describe "sr-Latn" do
    test "has three forms" do
      assert Plural.nplurals("sr-Latn") == 3
    end

    test "counts ending in 1 take the first form, except 11" do
      for count <- [1, 21, 31, 101, 1001] do
        assert Plural.plural("sr-Latn", count) == @one, "#{count} should take the first form"
      end
    end

    test "11 does not, which is the exception the first clause exists for" do
      for count <- [11, 111, 211] do
        assert Plural.plural("sr-Latn", count) == @other, "#{count} should take the third form"
      end
    end

    test "counts ending in 2, 3 or 4 take the second form" do
      for count <- [2, 3, 4, 22, 23, 24, 102, 1003] do
        assert Plural.plural("sr-Latn", count) == @few, "#{count} should take the second form"
      end
    end

    test "12, 13 and 14 do not, which is the exception the second clause exists for" do
      for count <- [12, 13, 14, 112, 113, 114] do
        assert Plural.plural("sr-Latn", count) == @other, "#{count} should take the third form"
      end
    end

    test "everything else takes the third form" do
      for count <- [0, 5, 6, 9, 10, 15, 20, 25, 100] do
        assert Plural.plural("sr-Latn", count) == @other, "#{count} should take the third form"
      end
    end

    test "the header it writes into a catalogue names three forms" do
      header = Plural.plural_forms_header("sr-Latn")

      assert header =~ "nplurals=3"
      assert header =~ "n%10==1"
    end
  end

  describe "every other locale" do
    # The control. Without it, a module that answered Serbian's rule for
    # everything would pass every row above.
    test "falls through to Gettext's own table" do
      assert Plural.nplurals("en") == 2
      assert Plural.plural("en", 1) == 0
      assert Plural.plural("en", 2) == 1
      assert Plural.plural("en", 21) == 1
    end

    test "and English does not acquire Serbian's exceptions" do
      # 11 and 12 are ordinary plurals in English; under Serbian's rule they
      # would land on a third form English does not have.
      assert Plural.plural("en", 11) == 1
      assert Plural.plural("en", 12) == 1
    end
  end
end
