# Demo Recording

## Prerequisites
- [asciinema](https://asciinema.org/) for recording
- [agg](https://github.com/asciinema/agg) for GIF conversion

## Record
```bash
asciinema rec demo.cast -c "bash demo/demo.sh"
```

## Convert to GIF
```bash
agg demo.cast demo.gif --cols 80 --rows 24
```
