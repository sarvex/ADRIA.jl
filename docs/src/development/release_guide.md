# Release Guide

## Public "Final" Releases

1. Run tests locally and ensure all pass.
2. Ensure all version numbers have been updated (check Project.toml file)
3. Submit PR from development branch into `main` and request code review/approval
4. Once PR is merged into main, go to the [releases page](https://github.com/open-AIMS/ADRIA.jl/releases) and draft a new release
5. Under "choose a tag" create a new tag "on publish"  
   Note version numbers should follow [Semantic Versioning](https://semver.org/)
6. Click the "Generate release notes" button (top-right of textbox).  
   Under "Whats new" add a short description of the major changes.  
   Explicitly note any major breaking changes (i.e., anything that results obtained with previous versions of ADRIA incompatible)
   DO NOT click "Publish release". Instead, copy the generated text
7. Register the updated package by opening a new issue with the title "Register [version number]"  
   e.g., `Register v1.0`
8. State in the comment: `@JuliaRegistrator register`
   Paste in the generated text from step 6 (an example is shown below)

```
@JuliaRegistrator register

Release notes:

Paste the generated release notes here.
```


See Julia Registrator usage notes [here](https://github.com/JuliaComputing/Registrator.jl?installation_id=32448289&setup_action=install#details-for-triggering-juliaregistrator-for-step-2-above) for more details.


## Development Release

Development releases provide users with the most recent "working" version of ADRIA and may still have some known bugs.
It provides users a chance to try new features and/or provide feedback before a public release.

Deploying a Development Release follows the same steps as "Public" releases, except:

1. Add "-dev.x" to the version number.  
   e.g., v1.2.3-dev.1; v1.2.3-dev.2 for the second development release, etc.
2. Untick "Set as the latest release" and tick the "Set as a pre-release" option.
3. DO click "Publish release", and DO NOT trigger the `JuliaRegistrator` bot.


## Release Candidates

Release candidates are releases that are not yet "final" but are close to it. Release candidates provide a "last chance" opportunity
for users to report bugs prior to a "final" release.

Deploying a Release Candidate follows the same steps as "Public" releases, except:

1. Add "-rc.x" to the version number.  
   e.g., v1.2.3-rc.1; v1.2.3-rc.2 for the second release candidate, etc.
2. Untick "Set as the latest release" and tick the "Set as a pre-release" option.
3. DO click "Publish release", and DO NOT trigger the `JuliaRegistrator` bot.

