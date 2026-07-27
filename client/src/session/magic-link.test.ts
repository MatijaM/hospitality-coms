import { describe, expect, it } from "vitest";

import { tokenFromPastedValue } from "./magic-link";

describe("tokenFromPastedValue", () => {
  it("takes the last path segment of a pasted link", () => {
    expect(tokenFromPastedValue("http://localhost:4000/log-in/AbC-123_x")).toBe(
      "AbC-123_x",
    );
  });

  it("takes the token itself when that is what was pasted", () => {
    expect(tokenFromPastedValue("AbC-123_x")).toBe("AbC-123_x");
  });

  it("ignores the whitespace a mail client wraps a link in", () => {
    expect(tokenFromPastedValue("  http://localhost:4000/log-in/AbC-123_x\n")).toBe(
      "AbC-123_x",
    );
  });

  it("ignores a trailing slash", () => {
    expect(tokenFromPastedValue("https://app.example.com/log-in/AbC-123_x/")).toBe(
      "AbC-123_x",
    );
  });

  it("reads through a link that carries a query string", () => {
    expect(
      tokenFromPastedValue("https://app.example.com/log-in/AbC-123_x?utm=mail"),
    ).toBe("AbC-123_x");
  });

  it("finds nothing in an empty paste", () => {
    expect(tokenFromPastedValue("   ")).toBeNull();
  });

  it("finds nothing in a link with no token on the end of it", () => {
    expect(tokenFromPastedValue("https://app.example.com/")).toBeNull();
  });
});
