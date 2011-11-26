# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "capistrano-optimized-git-deploy"
  s.version     = "0.9.9.1"
  s.authors     = ["Ewout Vonk"]
  s.email       = ["dev@ewout.to"]
  s.homepage    = "https://github.com/ewoutvonk/capistrano-optimized-git-deploy"
  s.summary     = %q{extension for capistrano which employs git revisions and the git reflog release management}
  s.description = %q{extension for capistrano which employs git revisions and the git reflog release management}

  s.rubyforge_project = "capistrano-optimized-git-deploy"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_runtime_dependency "capistrano"
end
