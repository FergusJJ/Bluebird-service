import ArgumentParser

/*

Need to: 
- Connect to db
- For each user:
    - get refresh token, last fetched time
    - get new access token
    - use access token to get 50 songs
    - insert songs into db
    - update the last fetched time
    - end 
- 

*/

@main
struct BluebirdService: ParsableCommand {

    @Option(help: "API access key")
    public var apikey: String

    public func run() throws {
        print("API KEY: \(self.apikey)")
    }

}
