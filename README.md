# The zig three

Are you [scared of javascript](https://eev.ee/blog/2016/10/31/javascript-a-horror-story/)? [Bad at CSS](https://www.keithcirkel.co.uk/bad-at-css/)? [Traumatised by HTML](https://devrant.com/rants/1554810/i-just-hate-when-stuff-like-this-happens)? Well now you can zig them all away. The zig three is a web framwork made in zig.

## Features

- Throw all your code in one file, with support for
    - Styling
    - Layout
    - Client code
    - Server code
- Hide away all unfortunate reminders there is no escape from
    - HTML
    - Javascript
    - CSS
- WASM support
    - Client code is automatically compiled into a wasm binary, stripped of excess symbols, and linked on all pages that use it.
    - A shared API for templating, client code, and server code. You only need to learn the naming once to use it everywhere.

# Disclaimer

This is a shitpost, please please please dont use this anywhere critical to you, especially the server code. I have no experience with security, and thus cannot make any safty promises.