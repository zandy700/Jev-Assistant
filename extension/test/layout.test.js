import { test } from "node:test";
import assert from "node:assert/strict";
import { parseHTML } from "linkedom";
import { readByLayout } from "../sites/layout.js";
import { fixtureRect } from "./helpers.js";

const html = `<body>
<div data-jev-rect="0,0,1000,900">
  <div data-jev-rect="0,0,300,900">
    <a href="/direct/t/1/"><span dir="auto" data-jev-rect="20,80,120,96">Sam</span></a>
    <span dir="auto" data-jev-rect="20,100,200,112">You: lol · 2h</span>
  </div>
  <div id="thread" data-jev-rect="300,0,1000,900">
    <a href="/sam/"><span dir="auto" data-jev-rect="360,20,420,40">Sam</span></a>
    <div dir="auto" data-jev-rect="360,100,560,120">post it somewhere</div>
    <div dir="auto" data-jev-rect="850,140,980,160">sending it now</div>
    <span dir="auto" data-jev-rect="360,180,480,192">Sam replied to you</span>
    <div dir="auto" data-jev-rect="370,196,470,214">sending it now</div>
    <div dir="auto" data-jev-rect="360,220,580,240">you cant buy bots</div>
    <div dir="auto" data-jev-rect="600,260,700,272">Today 2:41 PM</div>
    <div dir="auto" data-jev-rect="720,300,980,320">my feed is all spam now</div>
    <div data-jev-rect="330,850,980,890">
      <div role="textbox" contenteditable="true" data-jev-rect="380,855,900,885"><p></p></div>
    </div>
  </div>
</div>
</body>`;

test("layout reader: right side is me, inbox and reply quotes are dropped", () => {
  const { document } = parseHTML(html);
  const box = document.querySelector('[role="textbox"]');
  assert.deepEqual(readByLayout(box, fixtureRect, fixtureRect, 900).messages, [
    { side: "other", text: "post it somewhere" },
    { side: "me", text: "sending it now" },
    { side: "other", text: "you cant buy bots" },
    { side: "me", text: "my feed is all spam now" },
  ]);
});

test("layout reader: no message box means no chat", () => {
  assert.equal(readByLayout(null, fixtureRect, fixtureRect, 900), null);
});
