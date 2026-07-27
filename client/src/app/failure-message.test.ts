import { describe, expect, it } from "vitest";

import { KNOWN_ERROR_CODES } from "../api/errors";
import type { ErrorCode, RequestFailure } from "../api/errors";
import { failureMessage } from "./failure-message";

function apiError(code: ErrorCode, status: number): RequestFailure {
  return {
    kind: "api_error",
    status,
    code,
    rawCode: code,
    message: "a message written for whoever is reading the log",
  };
}

describe("failureMessage", () => {
  it.each<[ErrorCode, number, string]>([
    ["bad_request", 400, "That request was incomplete. Fill in the field and try again."],
    ["unauthorized", 401, "That is no longer valid. Ask for a new link."],
    ["not_found", 404, "That address does not exist on this server."],
    ["unprocessable_entity", 422, "That was not accepted."],
    [
      "internal_server_error",
      500,
      "Something went wrong on the server. Nothing was changed; try again.",
    ],
    ["bad_gateway", 502, "The email could not be sent right now. Try again in a moment."],
    [
      "unrecognised",
      418,
      "The server refused with a status this client does not know about (418).",
    ],
  ])("renders its own copy for %s", (code, status, expected) => {
    expect(failureMessage(apiError(code, status))).toBe(expected);
  });

  it("never renders the server's message, which the envelope says is for a log", () => {
    const rendered = KNOWN_ERROR_CODES.map((code) => failureMessage(apiError(code, 400)));

    expect(rendered).not.toContain("a message written for whoever is reading the log");
  });

  it("has copy for every code the client can decode", () => {
    // The switch is exhaustive by `strict` plus `noImplicitReturns` rather than
    // by a `default:`, so a code added without copy fails the build. This is
    // the runtime half of that: every code produces a non-empty string.
    const codes: ErrorCode[] = [...KNOWN_ERROR_CODES, "unrecognised"];

    for (const code of codes) {
      expect(failureMessage(apiError(code, 400))).not.toBe("");
    }
  });

  it("uses the same copy for a field error as for the bare error of that code", () => {
    expect(
      failureMessage({
        kind: "api_field_error",
        status: 422,
        code: "unprocessable_entity",
        rawCode: "unprocessable_entity",
        message: "the address was not accepted",
        fields: { email: ["must have the @ sign and no spaces"] },
      }),
    ).toBe("That was not accepted.");
  });

  it("tells the worker to check their connection when nothing answered", () => {
    expect(
      failureMessage({
        kind: "network_error",
        message: "Failed to fetch",
        cause: new TypeError("Failed to fetch"),
      }),
    ).toBe("The server could not be reached. Check your connection and try again.");
  });

  it("says nothing was changed when the answer was not the shape promised", () => {
    expect(
      failureMessage({
        kind: "malformed_response",
        status: 500,
        message: "the 500 response was not the error envelope",
      }),
    ).toBe(
      "The server answered in a way this client does not understand (500). Nothing was changed.",
    );
  });
});
