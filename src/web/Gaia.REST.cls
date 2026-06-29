Class Gaia.REST Extends %CSP.REST
{
XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/variations" Method="GET" Call="Variations"/>
</Routes>
}

ClassMethod Variations() As %Status
{
  // Coerce params to numbers so a non-numeric query string (e.g. ?x=abc) yields
  // a sane default instead of a 500 from float() inside the embedded-Python call.
  Set x = $Get(%request.Data("x",1), 10)
  Set:'$IsValidNum(x) x = 10
  Set limit = $Get(%request.Data("limit",1), 1000)
  Set:('$IsValidNum(limit))!(limit<1) limit = 1000
  Set limit = limit \ 1
  // Reuse the exact proxy SQL from src/gaia/sql.py via embedded Python (DRY).
  // build_query has a keyword-only `limit`; call the positional helper to avoid
  // keyword-arg friction across the ObjectScript<->Python boundary.
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/irisrun/repo")
  Set sqlmod = ##class(%SYS.Python).Import("src.gaia.sql")
  Set sql = sqlmod."build_query_limited"(x, limit)
  Set stmt = ##class(%SQL.Statement).%New()
  $$$ThrowOnError(stmt.%Prepare(sql))
  Set rs = stmt.%Execute()
  Set arr = []
  While rs.%Next() {
    Set o = {}
    Set o."source_id" = rs.%GetData(1), o.ra = rs.%GetData(2), o.dec = rs.%GetData(3)
    Set o."mag_max" = rs.%GetData(4), o."mag_min" = rs.%GetData(5), o."pct_change" = rs.%GetData(6)
    Do arr.%Push(o)
  }
  Do %response.SetHeader("Content-Type","application/json")
  Write arr.%ToJSON()
  Quit $$$OK
}
}
