import * as stylex from "@stylexjs/stylex";
import { surface, scheme } from "instrument";

import { Hero } from "./Hero";
import { BookIntro } from "./BookIntro";
import { ExamplesShowcase } from "./ExamplesShowcase";

// The app shell carries the base register (bg / ink / type) and pins the color
// scheme to dark — the marketing site is dark-first.
export default function App() {
  return (
    <div {...stylex.props(surface.root, scheme.dark)}>
      <Hero />
      <BookIntro />
      <ExamplesShowcase />
    </div>
  );
}
