<p align="center">
    <img alt="logo" src="res/logo.svg" width="10%" />
</p>

<h1 align="center">Nina</h1>
<p align="center">A minimal compiled programming language</p>

> [!CAUTION]
> Under active development

## Code Example

```cpp
mod main;

use std.io;

type Person(String name, int age);

int main(int argc, char** argv) {
    io.printn("Hello, World!");
    
    Person p = new Person("Christoffer", 57);

    ret 0;
}
```

```cpp
mod main;

ext void InitWindow(int width, int height, char* title);
ext void SetTargetFPS(int fps);
ext bool WindowShouldClose();
ext void BeginDrawing();
ext void ClearBackground(Color color);
ext void EndDrawing();
ext void CloseWindow();

type Color(int r, int g, int b, int a);

int main() {
    InitWindow(800, 600, "window");
    SetTargetFPS(60);

    while (!WindowShouldClose()) {
        BeginDrawing();
        ClearBackground(new Color(0, 0, 0, 255));
        EndDrawing();
    }

    CloseWindow();

    ret 0;
}
```

### Building the Compiler

```bash
c3c build
```

or using Makefile

```bash
make
```

## Contributing

Contributions are welcome! Please submit pull requests or open issues for any bugs or feature requests.

## [License](LICENSE)