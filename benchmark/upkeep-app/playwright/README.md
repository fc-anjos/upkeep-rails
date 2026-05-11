# upkeep-app Playwright tests

Browser-driven reactivity specs for the M3 idiom fixtures in `benchmark/upkeep-app`.

## Install

```sh
cd benchmark/upkeep-app/playwright
npm install
npm run install-browsers
```

## Run

From the signal-rails root (boots the app server automatically):

```sh
bin/playwright-test
```

Or, against an already-running server:

```sh
UPKEEP_APP_URL=http://localhost:3010 bin/playwright-test
```

Or directly from this directory (server must be running):

```sh
npm test
```
