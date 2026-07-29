import { describe, expect, it } from "vitest";

import { decodeErrorEnvelope, decodePerson, decodeSession } from "./decode";

describe("decodeErrorEnvelope", () => {
  it("reads an envelope with no fields as the no-fields member", () => {
    expect(
      decodeErrorEnvelope(401, {
        error: { code: "unauthorized", message: "no live session token" },
      }),
    ).toEqual({
      kind: "api_error",
      status: 401,
      code: "unauthorized",
      rawCode: "unauthorized",
      message: "no live session token",
    });
  });

  it("reads an envelope with fields as the field member", () => {
    expect(
      decodeErrorEnvelope(422, {
        error: {
          code: "unprocessable_entity",
          message: "not accepted",
          fields: { email: ["is invalid"] },
        },
      }),
    ).toMatchObject({ kind: "api_field_error", fields: { email: ["is invalid"] } });
  });

  it("treats an empty fields object as a field error, not as an absent one", () => {
    // `fields: {}` is a server that had a per-field failure and named nothing.
    // It is still the shape that says "this is about inputs", so it must not
    // collapse into the member whose whole meaning is that there are none.
    expect(
      decodeErrorEnvelope(422, { error: { code: "x", message: "y", fields: {} } }),
    ).toMatchObject({ kind: "api_field_error", fields: {} });
  });

  it("rejects the whole envelope when fields is not an object of message lists", () => {
    // The documented behaviour, and the reason for it: silently dropping a
    // malformed `fields` would render a validation failure with no complaint
    // attached to any input, which looks to the worker like a form that did
    // nothing.
    const notAnObject = decodeErrorEnvelope(422, {
      error: { code: "unprocessable_entity", message: "not accepted", fields: "email" },
    });
    const notLists = decodeErrorEnvelope(422, {
      error: {
        code: "unprocessable_entity",
        message: "not accepted",
        fields: { email: "is invalid" },
      },
    });
    const notStrings = decodeErrorEnvelope(422, {
      error: {
        code: "unprocessable_entity",
        message: "not accepted",
        fields: { email: [{ detail: "is invalid" }] },
      },
    });

    expect(notAnObject).toBeNull();
    expect(notLists).toBeNull();
    expect(notStrings).toBeNull();
  });

  it("keeps a code it does not know, rather than discarding it", () => {
    expect(
      decodeErrorEnvelope(418, { error: { code: "im_a_teapot", message: "hi" } }),
    ).toMatchObject({ code: "unrecognised", rawCode: "im_a_teapot" });
  });

  it("rejects anything that is not the envelope", () => {
    expect(
      decodeErrorEnvelope(500, { errors: { detail: "Internal Server Error" } }),
    ).toBeNull();
    expect(decodeErrorEnvelope(500, { error: "unauthorized" })).toBeNull();
    expect(decodeErrorEnvelope(500, { error: { code: 401, message: "no" } })).toBeNull();
    expect(decodeErrorEnvelope(500, { error: { code: "x" } })).toBeNull();
    expect(decodeErrorEnvelope(500, null)).toBeNull();
    expect(decodeErrorEnvelope(500, [])).toBeNull();
  });
});

describe("decodePerson", () => {
  it("accepts a null address, because erasure nulls it", () => {
    expect(
      decodePerson({ id: "abc", email: null, display_name: "Former colleague" }),
    ).toEqual({ id: "abc", email: null, displayName: "Former colleague" });
  });

  it("reads the display name the server gives every person", () => {
    expect(
      decodePerson({ id: "abc", email: "worker@example.com", display_name: "Puck" }),
    ).toEqual({ id: "abc", email: "worker@example.com", displayName: "Puck" });
  });

  it("rejects a person with no id, rather than one whose id is undefined", () => {
    expect(
      decodePerson({ email: "worker@example.com", display_name: "Puck" }),
    ).toBeNull();
  });

  it("rejects an address that is not a string or null", () => {
    expect(decodePerson({ id: "abc", email: 42, display_name: "Puck" })).toBeNull();
  });

  it("rejects an address key that is missing entirely", () => {
    expect(decodePerson({ id: "abc", display_name: "Puck" })).toBeNull();
  });

  it("rejects a person with no display name rather than rendering a placeholder", () => {
    // #66. `display_name` is `NOT NULL` on the server and an erased person
    // carries a value rather than a null, so there is no body this refuses that
    // the API can produce — and a fallback here would show every person under
    // one invented string the moment the field stopped arriving.
    expect(decodePerson({ id: "abc", email: "worker@example.com" })).toBeNull();
    expect(
      decodePerson({ id: "abc", email: "worker@example.com", display_name: null }),
    ).toBeNull();
  });
});

describe("decodeSession", () => {
  it("rejects a session whose person does not decode", () => {
    expect(
      decodeSession({
        token: "abc",
        person: { email: "worker@example.com", display_name: "Puck" },
      }),
    ).toBeNull();
  });

  it("rejects a session with no token", () => {
    expect(
      decodeSession({ person: { id: "abc", email: null, display_name: "Puck" } }),
    ).toBeNull();
  });
});
