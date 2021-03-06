{ stdenv
, buildPythonPackage
, fetchPypi
, python
, pkgs
, pillow
, twitter
, pyfiglet
, requests
, arrow
, dateutil
, pysocks
, pocket
}:

buildPythonPackage rec {
  pname = "rainbowstream";
  version = "1.3.7";

  src = fetchPypi {
    inherit pname version;
    sha256 = "0zpi1x3b535pwx8rkq57nnrb5d5ma65vvlalar9vi6ilp124x1w2";
  };

  patches = [ ./image.patch ];

  postPatch = ''
    clib=$out/${python.sitePackages}/rainbowstream/image.so
    substituteInPlace rainbowstream/c_image.py \
      --replace @CLIB@ $clib
    sed -i 's/requests.*"/requests"/' setup.py
  '';

  LC_ALL="en_US.UTF-8";

  postInstall = ''
    mkdir -p $out/lib
    cc -fPIC -shared -o $clib rainbowstream/image.c
    for prog in "$out/bin/"*; do
      wrapProgram "$prog" \
        --prefix PYTHONPATH : "$PYTHONPATH"
    done
  '';

  buildInputs =  [ pkgs.libjpeg pkgs.freetype pkgs.zlib pkgs.glibcLocales pillow twitter pyfiglet requests arrow dateutil pysocks pocket ];

  meta = with stdenv.lib; {
    description = "Streaming command-line twitter client";
    homepage    = "http://www.rainbowstream.org/";
    license     = licenses.mit;
    maintainers = with maintainers; [ thoughtpolice ];
  };

}
