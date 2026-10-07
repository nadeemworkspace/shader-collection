SwiftUI app with a collection of Metal shaders

## Effects

- **Carousel** – 3D cards refracted through a glass edge (flip and drum styles).
- **Globe** – a country picker over a dotted globe ray-cast in Metal. Pick a region to
  turn the globe to it and light it up, then a country (or tap one on the globe) to fly
  in and reveal it on a finer grid of dots.

Country shapes come from [Natural Earth](https://www.naturalearthdata.com) (public
domain), baked into a country-ID map by `Tools/BakeCountryMap.swift`.
