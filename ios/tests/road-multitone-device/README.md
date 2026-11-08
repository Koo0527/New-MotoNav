# Native map-processing measurement probe

This is a compile-only test tool. It is not included in the production Xcode project and never installs or launches an app itself.

`python3 ios/tests/road-multitone-device/build.py --mode baseline` builds the pre-change classifier from this task's frozen source snapshot. `--mode current` builds the current three production processing files. Both need the signed seed app at `output/road-multitone/DD-baseline/Build/Products/Release-iphoneos/MotoNav.app`, the five captured input regions, and the existing development signing identity. Existing output directories are refused to preserve evidence.

The probe uses the existing app identity, so installing it temporarily replaces the normal UI while retaining the application data container. It must be followed by installation and launch verification of a normal signed app. An installation receipt or matching version alone does not prove that restoration completed. Do not install this tool while device tests are paused.

Five identical raw sampled regions are bundled, each with one 1200² base and four 600² building inputs. Each scene runs seven times; the first is warm-up. The report records process CPU, wall time, process maximum RSS, thermal state, packet sizes and format marker. The measured block reads inputs, classifies roads, encodes, simplifies four building patches, composes and validates. It excludes SDK screenshot/network work, real BLE, navigation UI and G. It is not a full-app or on-road performance measurement.

Reports are written atomically to `Documents/MotoNav-Diagnostics/tone-probe-{baseline,current}.json`. Check the actual mode, format marker, input hashes and host-side source/executable manifest before comparing. Use fresh report/output locations so stale data cannot be mistaken for a new run. The app keeps the screen awake only after it successfully launches.

The probe adopts `UIWindowSceneDelegate` and supplies a matching scene manifest. On the iOS 27.2 test phone, the earlier legacy app-delegate-only probe trapped in `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` before producing a report; the normal App was restored. This lifecycle fix affects the isolated tool only, not the measured processing files or production App. Both comparison modes must use the same corrected probe source.

On 2026-11-04, device install/launch attempts suffered CoreDevice tunnel and installation-service interruptions. No complete phone report was obtained. The user subsequently paused device work; final app identity, restoration and actual phone performance remain to be verified when device testing resumes. Current probe artifacts created before the validator optimization are stale and must be rebuilt before use. Host-only comparisons under `output/road-multitone/` must not be reported as phone results.
