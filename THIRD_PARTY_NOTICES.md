# Third-Party Notices

The distributed app carries third-party code as: statically linked inside
`CJarvisAEC.xcframework`, embedded as `Sparkle.framework` at `Contents/Frameworks/`,
shipped as trained model weights in `Contents/Resources/Jarvis_JarvisApp.bundle`, and bundled as the
CLIProxyAPI executable at `Contents/MacOS/cliproxyapi`. The native References helper at
`Contents/Resources/ReferenceHelper/JarvisReferenceHelper` links macOS's system SQLite library.
The helper also statically links ZIPFoundation for streamed DOCX ZIP access and uses system PDFKit.
SQLite is public domain (https://www.sqlite.org/copyright.html); no SQLite code or separate runtime
is bundled. These notices accompany binary distributions.


`CJarvisAEC.xcframework` is a checksum-pinned universal static library downloaded by SwiftPM
(see `Package.swift`). The maintainer recipe, `scripts/build-aec.sh`, statically links the following
third-party components into the app. Their licenses require these notices with binary distributions.
The hosted XCFramework also includes exact upstream license files and build provenance.

---

## webrtc-audio-processing (the AEC3 echo canceller)

- Source: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing (tag `v2.1`)
- License: **BSD-3-Clause**
- Copyright (c) 2011, The WebRTC project authors. All rights reserved.

```
Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions
    and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of
    conditions and the following disclaimer in the documentation and/or other materials provided
    with the distribution.
  * Neither the name of Google nor the names of its contributors may be used to endorse or promote
    products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The hosted XCFramework includes upstream `COPYING`, `AUTHORS`, `LICENSE`, and `PATENTS` files.

---

## abseil-cpp (bundled by webrtc-audio-processing's wrap, statically linked)

- Source: https://github.com/abseil/abseil-cpp (release `20240722.0`, built via the webrtc wrap)
- License: **Apache-2.0**
- Copyright The Abseil Authors.

This product includes software developed by The Abseil Authors, licensed under the Apache License,
Version 2.0. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
Apache-2.0 §4 requires retaining this attribution and the upstream NOTICE (if any) in distributions;
abseil ships no separate NOTICE file. Its full Apache-2.0 license and `AUTHORS` are included in the
hosted XCFramework; the Apache-2.0 text also accompanies the app as `LICENSE`.

---

## WebRTC embedded third-party components

The audio-processing archive also contains the following upstream components.

### webrtc/third_party/pffft

```
Copyright (c) 2013  Julien Pommier ( pommier@modartt.com )

Based on original fortran 77 code from FFTPACKv4 from NETLIB,
authored by Dr Paul Swarztrauber of NCAR, in 1985.

As confirmed by the NCAR fftpack software curators, the following
FFTPACKv5 license applies to FFTPACKv4 sources. My changes are
released under the same terms.

FFTPACK license:

http://www.cisl.ucar.edu/css/software/fftpack5/ftpk.html

Copyright (c) 2004 the University Corporation for Atmospheric
Research ("UCAR"). All rights reserved. Developed by NCAR's
Computational and Information Systems Laboratory, UCAR,
www.cisl.ucar.edu.

Redistribution and use of the Software in source and binary forms,
with or without modification, is permitted provided that the
following conditions are met:

- Neither the names of NCAR's Computational and Information Systems
Laboratory, the University Corporation for Atmospheric Research,
nor the names of its sponsors or contributors may be used to
endorse or promote products derived from this Software without
specific prior written permission.

- Redistributions of source code must retain the above copyright
notices, this list of conditions, and the disclaimer below.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions, and the disclaimer below in the
documentation and/or other materials provided with the
distribution.

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING, BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE CONTRIBUTORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH THE
SOFTWARE.
```

### webrtc/third_party/rnnoise

```
Copyright (c) 2017, Mozilla
Copyright (c) 2007-2017, Jean-Marc Valin
Copyright (c) 2005-2017, Xiph.Org Foundation
Copyright (c) 2003-2004, Mark Borgerding

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.Org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### webrtc/common_audio/third_party/ooura

```
/*
 * http://www.kurims.kyoto-u.ac.jp/~ooura/fft.html
 * Copyright Takuya OOURA, 1996-2001
 *
 * You may use, copy, modify and distribute this code for any purpose (include
 * commercial use) and without fee. Please refer to this package when you modify
 * this code.
 */
```

### webrtc/common_audio/third_party/spl_sqrt_floor

```
/*
 * Written by Wilco Dijkstra, 1996. The following email exchange establishes the
 * license.
 *
 * From: Wilco Dijkstra <Wilco.Dijkstra@ntlworld.com>
 * Date: Fri, Jun 24, 2011 at 3:20 AM
 * Subject: Re: sqrt routine
 * To: Kevin Ma <kma@google.com>
 * Hi Kevin,
 * Thanks for asking. Those routines are public domain (originally posted to
 * comp.sys.arm a long time ago), so you can use them freely for any purpose.
 * Cheers,
 * Wilco
 *
 * ----- Original Message -----
 * From: "Kevin Ma" <kma@google.com>
 * To: <Wilco.Dijkstra@ntlworld.com>
 * Sent: Thursday, June 23, 2011 11:44 PM
 * Subject: Fwd: sqrt routine
 * Hi Wilco,
 * I saw your sqrt routine from several web sites, including
 * http://www.finesse.demon.co.uk/steven/sqrt.html.
 * Just wonder if there's any copyright information with your Successive
 * approximation routines, or if I can freely use it for any purpose.
 * Thanks.
 * Kevin
 */
```

### webrtc/modules/third_party/fft

```
/*
 * Copyright(c)1995,97 Mark Olesen <olesen@me.QueensU.CA>
 *    Queen's Univ at Kingston (Canada)
 *
 * Permission to use, copy, modify, and distribute this software for
 * any purpose without fee is hereby granted, provided that this
 * entire notice is included in all copies of any software which is
 * or includes a copy or modification of this software and in all
 * copies of the supporting documentation for such software.
 *
 * THIS SOFTWARE IS BEING PROVIDED "AS IS", WITHOUT ANY EXPRESS OR
 * IMPLIED WARRANTY.  IN PARTICULAR, NEITHER THE AUTHOR NOR QUEEN'S
 * UNIVERSITY AT KINGSTON MAKES ANY REPRESENTATION OR WARRANTY OF ANY
 * KIND CONCERNING THE MERCHANTABILITY OF THIS SOFTWARE OR ITS
 * FITNESS FOR ANY PARTICULAR PURPOSE.
 *
 * All of which is to say that you can do what you like with this
 * source code provided you don't try to sell it as your own and you
 * include an unaltered copy of this message (including the
 * copyright).
 *
 * It is also implicitly understood that bug fixes and improvements
 * should make their way back to the general Internet community so
 * that everyone benefits.
 */
```

---

## Sparkle (the in-app updater, embedded framework)

- Source: https://github.com/sparkle-project/Sparkle (release `2.9.6`)
- License: **MIT**, with the additional external licenses reproduced below
- Copyright (c) 2006-2013 Andy Matuschak and the Sparkle contributors listed below

Embedded at `Contents/Frameworks/Sparkle.framework` in the distributed bundle by
`scripts/package-app.sh`. The upstream `LICENSE` is reproduced in full, including the external
notices Sparkle carries for bsdiff, sais-lite, the portable Ed25519 implementation, and
`SUSignatureVerifier.m`.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## Silero VAD (the local voice-activity detector)

- Source: https://github.com/snakers4/silero-vad (revision `7e30209a3e90`, tag `v6.2.1`)
- License: **MIT**
- Copyright (c) 2020-present Silero Team

`Sources/JarvisApp/Resources/SileroVAD.mlmodelc` is the upstream 16 kHz model converted to Core ML by
`scripts/build-vad.sh`, and is shipped inside the app bundle at
`Contents/Resources/Jarvis_JarvisApp.bundle`. It carries the upstream trained weights, so this notice
accompanies every binary distribution.

```
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## CLIProxyAPI (the subscription helper, bundled executable)

- Source: https://github.com/router-for-me/CLIProxyAPI (release pinned in `scripts/lib/cliproxyapi.sh`)
- License: **MIT**
- Copyright (c) 2025-2005.9 Luis Pater; Copyright (c) 2025.9-present Router-For.ME

The app bundle carries a binary built from the pinned upstream source with Jarvis's
`scripts/cliproxyapi/local-only.patch` at `Contents/MacOS/cliproxyapi`, with its upstream license
beside it at `Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt`. The patch omits remote SSH/IP
discovery and the Antigravity and Grok version updaters, which Jarvis does not use.

```
MIT License

Copyright (c) 2025-2005.9 Luis Pater
Copyright (c) 2025.9-present Router-For.ME

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## ZIPFoundation (native DOCX archive access)

- Source: https://github.com/weichsel/ZIPFoundation (exact tag `0.9.20`, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`)
- License: **MIT**
- Runtime: statically linked in `JarvisReferenceHelper`; uses Apple system compression APIs on macOS.

```
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
