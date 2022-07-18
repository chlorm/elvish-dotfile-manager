# Copyright (c) 2016, 2018-2022, Cody Opel <cwopel@chlorm.net>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# FIXME: maybe make this a generic git updater
#   https://github.com/chlorm/kratos/blob/c82657c9565ce041ade093c473c3f6d0b25be0ad/modules/updater/main.bash


use github.com/chlorm/elvish-stl/env
use github.com/chlorm/elvish-stl/exec
use github.com/chlorm/elvish-stl/io
use github.com/chlorm/elvish-stl/map
use github.com/chlorm/elvish-stl/os
use github.com/chlorm/elvish-stl/path
use github.com/chlorm/elvish-stl/re
use github.com/chlorm/elvish-stl/str
use github.com/chlorm/elvish-xdg/xdg-dirs


var EXT-GENERATE = '.generate'
var EXT-INSTALL-PRE = '.install-pre'
var EXT-INSTALL = '.install'
var EXT-INSTALL-POST = '.install-post'

# TODO:
# - Should we use an ext for os-specific hooks or require implementing os logic as needed in hooks
# - allow many repos
# - clone to a single directory
# - link or install files from the lib dir
# - track all linked/installed files
# - add-repo, add-file, add-directory, update-file commands
# - Figure out windows support, possibly in a more minimal fashion.
#   - Windows cannot use symlinks as they require admistrator privledges.
#   - Need to rewrite current system to install files instead of symlinking

# Parse `@{VAR}@`
fn -environment-variable-parse-tmpl {|fileStr|
    re:find '(@{.*?}@)' $fileStr
}

fn -environment-variable-parse-tmpl-inner {|varTmplStr|
    re:find '@{(.*?)}@' $varTmplStr
}

# FIXME: add try/catch with useful error
fn -environment-variable-evaluate {|varNameStr|
    env:get $varNameStr
}

fn -environment-variable-repls {|fileStr|
    -environment-variable-parse-tmpl $fileStr | peach {|v|
        put [
            $v
            (-environment-variable-parse-tmpl-inner $v)
        ]
    }
}

# Parse `@(command --arg)@`
fn -command-substitution-parse-tmpl {|fileStr|
    re:find '(@\(.*?\)@)' $fileStr
}

fn -command-substitution-parse-tmpl-inner {|csTmpl|
    re:find '@\((.*?)\)@' $csTmpl
}

fn -command-substatution-evaluate {|cmd|
    put (e:elvish -c $cmd)
}

fn -command-substitution-repls {|fileStr|
    -command-substitution-parse-tmpl $fileStr | peach {|cs|
        put [
            $cs
            (-command-substitution-parse-tmpl-inner $cs)
        ]
    }
}

# Replace template sting with evaluated string.
fn -repl-tmpl {|replPair fileStr|
    str:replace $replPair[0] $replPair[1] $fileStr
}

fn -evaluate-repls {|fileStr|
    run-parallel {
        -environment-variable-repls $fileStr | peach {|r|
            put [
                $r[0]
                (-environment-variable-evaluate $r[1])
            ]
        }
    } {
        -command-substitution-repls $fileStr | peach {|r|
            put [
                $r[0]
                (-command-substitution-evaluate $r[1])
            ]
        }
    }
}

# TODO: maybe make repls an arg instead of calling here so that this only
#       subs repls.  Input is already sync so it would have no affect.
fn -sub-repls {|fileStr|
    for i [ (-evaluate-repls $fileStr) ] {
        set fileStr = (-repl-tmpl $i $fileStr)
    }
    put $fileStr
}

fn -install-path {|dotfile|
    put (path:join (path:home) '.'$dotfile)
}

fn -hook-generate {|dotfilePath dotfilesDir dotfile|
    var fileStr = (-sub-repls (io:open $dotfilePath))
    # Override vars
    set dotfile = (str:replace $EXT-GENERATE '' $dotfile)
    set dotfilePath = (path:join $dotfilesDir $dotfile)
    # FIXME: not sure we want to install this way, but works for now
    echo $fileStr > $dotfilePath
}

fn -hook-run-script {|script|
    try {
        e:elvish $script
    } catch error {
        fail $error
    }
}

fn -hook-install {|dotfilesDir dotfile|
    var installPath = (-install-path $dotfile)
    if (not (os:exists $installPath)) {
        echo 'Installing: '$dotfile >&2
    } else {
        echo 'Updating: '$dotfile >&2
    }

    # FIXME: Test symlink target before removing
    if (os:exists $installPath) {
        os:remove $installPath
    }

    if (not (os:is-dir (path:dirname $installPath))) {
        os:makedirs (path:dirname $installPath)
    }
    os:symlink (path:join $dotfilesDir $dotfile) $installPath
}

fn install-singleton {|dotfilesDir dotfile|
    var dotfilePath = (path:join $dotfilesDir $dotfile)

    # Generate
    if (str:has-suffix $dotfile $EXT-GENERATE) {
        -hook-generate $dotfilePath $dotfilesDir $dotfile
        set dotfile = (re:replace '.generate$' '' $dotfile)
    } elif (os:exists $dotfilePath$EXT-GENERATE) {
        return
    }

    # PRE-Install
    var dotInstallPre = $dotfilePath$EXT-INSTALL-PRE
    if (os:exists $dotInstallPre) {
        -hook-run-script $dotInstallPre
    }

    # Install
    var dotInstall = $dotfilePath$EXT-INSTALL
    if (os:exists $dotInstall) {
        -hook-run-script $dotInstall
    } else {
        -hook-install $dotfilesDir $dotfile
    }

    # POST-Install
    var dotInstallPost = $dotfilePath$EXT-INSTALL-POST
    if (os:exists $dotInstallPost) {
        -hook-run-script $dotInstallPost
    }
}

fn -path-rel-to-home {|path|
    var home = (path:absolute (path:home))
    set path = (path:relative-to $path $home)
    set path = (re:replace '^\.' '' $path)
    put $path
}

fn -path-rel-to-dotfilesdir {|dotfilesDir path|
    set dotfilesDir = (path:absolute $dotfilesDir)
    path:relative-to $path $dotfilesDir
}

fn -build-ignore-list {|dotfilesDir|
    var ignoreList = [
        (path:join (-path-rel-to-home (xdg-dirs:config-home)) 'systemd')
    ]

    var dotIgnore = (path:join $dotfilesDir '.dotignore')
    if (os:is-file $dotIgnore) {
        set ignoreList = [
            $@ignoreList
            (-path-rel-to-dotfilesdir $dotfilesDir $dotIgnore)
            (str:to-lines (io:open $dotIgnore))
        ]
    }
    put $ignoreList
}

fn -should-ignore {|ignoreList dotfilesDir dotfile|
    # Exclude hooks
    # FIXME: don't exclude .install, allow install without an associated dotfile
    var dotfileHooks = [
        $EXT-INSTALL-PRE
        $EXT-INSTALL
        $EXT-INSTALL-POST
    ]
    for hook $dotfileHooks {
        if (str:has-suffix $dotfile $hook) {
            put $true
            return
        }
    }

    set dotfile = (-path-rel-to-dotfilesdir $dotfilesDir $dotfile)
    # Ignore hidden files
    if (path:is-hidden $dotfile) {
        put $true
        return
    }

    for ignore $ignoreList {
        if (==s '' $ignore) {
            continue
        }
        # Respect ignoring files within ignored directories
        if (re:match '.*'$ignore'.*' $dotfile) {
            put $true
            return
        }
    }
    put $false
}

fn -find-files {|dotfilesDir|
    if (not (os:is-dir $dotfilesDir)) {
        fail 'Dotfile directory does not exist: '$dotfilesDir
    }

    var ignoreList = (-build-ignore-list $dotfilesDir)

    var dotfiles = [ ]
    # These loops should remain synchronous to avoid hitting open file limits.
    # The issue is actually install-singleton/-hook-generate accessing to
    # many files.  Making this sync is slow enough to avoid hitting the limit
    # and still faster than running install-singleton in sync.
    for path [ (path:walk $dotfilesDir) ] {
        var dir = $path['root']
        for file $path['files'] {
            var dotfile = (path:join $dir $file)
            if (-should-ignore $ignoreList $dotfilesDir $dotfile) {
                continue
            }
            put (-path-rel-to-dotfilesdir $dotfilesDir $dotfile)
        }
    }
}

# FIXME: support multiple dirs (repos)
fn install {|dotfilesDir|
    xdg-dirs:populate-env

    -find-files $dotfilesDir | peach {|dotfile|
        install-singleton $dotfilesDir $dotfile
    }
}

fn update {
    # TODO
}

