# ft_sdk_ext Notes

This module has a special dependency resolution setup for local HAR development.

## Why `oh-package.json5` still references `ft_sdk`

[`oh-package.json5`](/Users/Brandon/DevEcoStudioProjects/ft-sdk-harmonyos/ft_sdk_ext/oh-package.json5) contains a local `ft_sdk` reference so `ft_sdk_ext` can pass its own module-level dependency parsing during local build and packaging.

That reference is not the final dependency source used by the consumer app.

At app/demo integration time, the root [`oh-package.json5`](/Users/Brandon/DevEcoStudioProjects/ft-sdk-harmonyos/oh-package.json5) uses `overrides` to replace that module-local reference with the consumer-side local HAR mapping.

In short:

- `ft_sdk_ext/oh-package.json5`: build-time placeholder/reference for this module
- root `oh-package.json5` `overrides`: final consumer-side resolution

## Why there is an empty `ft_sdk.har`

The empty [`ft_sdk.har`](/Users/Brandon/DevEcoStudioProjects/ft-sdk-harmonyos/ft_sdk_ext/ft_sdk.har) file exists only to avoid syntax/path validation failures while `ft_sdk_ext` is being parsed locally.

It is not a real SDK artifact and must not be used for publishing or app integration.

The real package used for build output and app/demo consumption should come from the actual `ft_sdk` HAR artifact.
