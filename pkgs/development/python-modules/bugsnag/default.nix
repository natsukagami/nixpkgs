{ lib
, blinker
, buildPythonPackage
, fetchPypi
, flask
, pythonOlder
, webob
}:

buildPythonPackage rec {
  pname = "bugsnag";
  version = "4.6.2";
  format = "setuptools";

  disabled = pythonOlder "3.5";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-UwlT4a0jzp6vo5ZpB/o3MKJAFHpaDJBcaQvFoctS120=";
  };

  propagatedBuildInputs = [
    webob
  ];

  passthru.optional-dependencies = {
    flask = [
      blinker
      flask
    ];
  };

  pythonImportsCheck = [
    "bugsnag"
  ];

  # Module ha no tests
  doCheck = false;

  meta = with lib; {
    description = "Automatic error monitoring for Python applications";
    homepage = "https://github.com/bugsnag/bugsnag-python";
    changelog = "https://github.com/bugsnag/bugsnag-python/blob/v${version}/CHANGELOG.md";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
  };
}
